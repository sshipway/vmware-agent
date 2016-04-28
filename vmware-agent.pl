#!/usr/bin/perl
# vim:ts=4
#
# vmware-agent.pl
# Version 0.2 : Steve Shipway, The University of Auckland
#
# This script collects data from vmware API and passes on to configured
# output; usually, Nagios and MRTG
#
# This requires Nagios LiveStatus plugins, and/or MRTG rrdcached
#
# You will need to install:
#    VI Perl Toolkit (download from VMware website)
#    Class::MethodMaker
#    SOAP::Lite
#    XML::LibXML
#    Template::Toolkit (if creating config files)
#    POSIX
#    Net::NTP (if you want time synch checks)
#     ... and all dependent modules
#    You need at least v5.832 of HTTP::Message! ***IMPORTANT***
#
# vmware-agent.pl --config=file.cfg
#
# Exit status:
#    0 = OK
#    1 = input error (VMware tools)
#    2 = output error (Nagios, MRTG, etc)
#    3 = initialisation error (cfg file)
#
##########################################################################
# Version history
# 0.1 First working: all graphs and Services for dc/cluster/host/guest
# 0.2 
#
##########################################################################

use strict;
use VMware::VIRuntime;
use VMware::VILib;
use Getopt::Long;
use FindBin qw($Bin);
use IO::Socket;
use Data::Dumper; # for debug
use Cwd;
use POSIX "setsid";
my($VERSION) = "0.2";

##########################################################################
my($CFGFILE) = "vmware-agent.cfg"; # searched in $bin, $cwd, $bin/../etc, /etc, /usr/local/etc ..
my(%config)=();
my(%servicedesc)=();
my(%rrdfiles)=();
my($livestatus) = 0;
my($duplivestatus) = 0;
my($livestatuserr) = 0;
my($duplivestatuserr) = 0;
my($vmware) = 0;
my(%ntp) = ();
my($has_naglog, $has_syslog, $has_logfile) = (0,0,0);
my($start,$delay);
my($datacenters, $clusters, $hosts, $guests);
my($tt);
my(%cfghosts)=();
my($si_view,$sc_view,$interval,$intervalid,$perfmgr);
my(%perfkeys) = ();
##########################################################################
# Default configuration values
%config = (
	global => {
	 'timeout'         => 60,
	 'frequency'       =>300,
	 'guests'          =>  1,
	 'clusters'        =>  1,
	 'hosts'           =>  1,
	 'daemon'          =>  1,
	},
	nagios => {
	 'thresh_cpu_warn' => 80,# %
	 'thresh_cpu_crit' => 90,# %
	 'thresh_mem_warn' => 80,# %
	 'thresh_mem_crit' => 90,# %
	 'thresh_rdy_warn' =>  5,# %
	 'thresh_rdy_crit' => 10,# %
	 'thresh_dsk_warn' =>10240,
	 'thresh_dsk_crit' => 1024, #MB
	 'thresh_swp_warn' => 10, # %
	 'thresh_swp_crit' =>100, # %
	 'thresh_bal_warn' =>  5, # %
	 'thresh_bal_crit' =>100, # %
	 'thresh_ntp_warn' =>  1, # sec
	 'thresh_ntp_crit' =>  5, # sec
	 'thresh_swapin_warn' =>  1, # k/sec
	 'thresh_swapin_crit' =>  5, # k/sec
	 'thresh_latency_warn' =>  10, # msec
	 'thresh_latency_crit' =>  50, # msec
	 'canonicalise'    =>  1,
	 'tolower'         =>  1,
	 'enable'		   =>  0,
	 'cfg'			   =>  0,
	 'verify'          =>  1, 
     'verify_warning'  =>  1,
	 'ntp'             => 'never',
	},
	mrtg => {
	 'cfgheader'         => '',
	 'enable'			=> 0,
	 'cfg'				=> 0,
	},
	syslog => {
	 'facility'        =>'daemon',
	},
	logfile => {
	 'append'         =>  1,
	 'level'          =>  0,
	 'rotate'         => 'n',
	 'file'           => '/var/log/vmware-agent.log',
	},
);
# Identify the name of the Nagios service
%servicedesc = (
	datacenters => {
		alarms => 'VMware: Alarms',
		datastores => 'VMware: Datastores',
		datastore => 'VMware: Datastore',
		status => 'VMware: Status',
	},
	clusters => {
		status => 'VMware: Status',
		alarms => 'VMware: Alarms',
		memory => 'VMware: Cluster Memory',
		cpu    => 'VMware: Cluster CPU',
		datastores => 'VMware: Datastores',
		datastore => 'VMware: Datastore',
		interface => 'VMware: Net',
		fairness => 'VMware: Balance',
	},
	hosts => {
		alarms => 'VMware: Alarms',
		memory => 'VMware: Host Memory',
		cpu    => 'VMware: Host CPU',
		datastores => 'VMware: Datastores',
		datastore => 'VMware: Datastore',
		status => 'VMware: Status',
		'time' => 'VMware: Time Sync',
		fairness => 'VMware: Balance',
		disk   => 'VMware: Disk',
		net    => 'VMware: Network',
		interface => 'VMware: Net',
		info   => 'VMware: Info',
	},
	guests => {
		alarms => 'VMware: Alarms',
		memory => 'VMware: Memory',
		cpu    => 'VMware: CPU',
		status => 'VMware: Status',
		disk   => 'VMware: Disk',
		net    => 'VMware: Network',
		interface => 'VMware: Net',
		info   => 'VMware: Info',
	}
);
# identify the name of the rrdfile.  Prepended with object name.
%rrdfiles = (
	datacenters => {
		active    => 'dc-active-vms',
		datastores => 'dc-datastores', # summary
		datastore => 'dc-ds',          # detail
		interface => 'dc-net',
	},
	clusters => {
		active    => 'ccr-active-vms',
		resources => 'ccr-resources',
		datastores => 'ccr-datastores',
		datastore => 'ccr-ds',
		interface => 'ccr-net',
		fairness  => 'ccr-fair',
	},
	hosts => {
		active    => 'active-vms',
		resources => 'resources',
		datastores => 'datastores',
		datastore => 'ds',
		interface => 'net',
		fairness  => 'fair',
		disk      => 'disk',
		swap      => 'swap',
		net       => 'network',
		latency   => 'latency',
	},
	guests => {
		resources => 'resources',
		cpu1      => 'cpu-used-rdy',
		cpu2      => 'cpu-sys-wait',
		cpu       => 'cpu-combined',
		memory    => 'mem-active',
		mem1      => 'mem-pvt-shr',
		mem2      => 'mem-bal-swp',
		mem       => 'mem-combined',
		disk      => 'disk',
		network   => 'network',
		latency   => 'latency',
	},
);
##########################################################################
my($DEBUG) = 0;    
my(%SYSLOG) = (
	0=>'err', 1=>'warning', 2=>'info', 3=>'debug', 4=>'debug'
);
my(%mapstatus) = (
	green=>0,yellow=>1,red=>2,grey=>3,
	ok=>0,warn=>1,warning=>1,crit=>2,critical=>2,unknown=>3,
	up=>0,down=>1,unreachable=>2,
	poweredOn=>0, poweredOff=>1,running=>0,notRunning=>1,
);

$|=1;
$Util::script_version = $VERSION;
$SIG{CHLD} = sub { print "SIGCHLD\n" if($DEBUG); };
$SIG{ALRM} = sub { die('TIMEOUT'); };

# predefines
sub send_nagios_status($$$$);

# level: 0=error, 1=warn, 2=info, 3=debug, 4=trace
sub do_log($$) {
	my($level,$msg) = @_;

	$msg =~ s/[ \n\r]+$//; # trim trialing newlines and spaces
	if($DEBUG == 0) {
		print "$msg\n" if($level<1);
	} elsif( $level < ($DEBUG+2)) {
		print "$msg\n";
	}

	if($has_syslog) {
		my $slmsg = $msg;
		$slmsg =~ s/\n/ - /g;
		Sys::Syslog::syslog($SYSLOG{$level},"%s",$slmsg);
	}

	if($has_logfile) {
		print LOGFILE "[".POSIX::strftime('%d/%m/%y %H:%M',localtime())."] $msg\n" 
			if($level <= $config{'logfile'}{'level'});
	}

	if($has_naglog and $level < 3) {
		my $naglvl = 0;
		if( $level == 0 ) { $naglvl = 2; } # critical
		elsif( $level == 1 ) { $naglvl = 1; } # warning
		send_nagios_status( 
			$config{'nagios'}{'log_hostname'},
			$config{'nagios'}{'log_servicedesc'},
			$naglvl,
			$msg
		);
	}
}

sub readconfig() {
	my($line);
	my($section) = '';
	my($key,$val);
	if( $CFGFILE !~ /^\// ) {
		foreach my $p ( $Bin, $Bin."/../etc", '/etc','/usr/local/etc','/etc/nagios','/usr/local/nagios/etc','/opt/nagios/etc', cwd() ) {
			if( -r "$p/$CFGFILE" ) {
				$CFGFILE = "$p/$CFGFILE";
				last;
			}
		}
	}
	print "Reading configuration file $CFGFILE\n" if($DEBUG);
	if( ! -r $CFGFILE ) {
		print "Unable to open configuration file '$CFGFILE'\n";
		exit 3;
	}
	open CFG, "<$CFGFILE" or do {
		print "Unable to read configuration file '$CFGFILE'\n$!\n";
		exit 3;
	};
	while( defined ($line = <CFG>) ) {
		next if ( $line =~ /^\s*#/ );
		next if ( $line =~ /^\s*$/ );
		if ( $line =~ /^\s*\[(\S+)\]/ ) { 
			$section = lc $1; 
			print "Section [$section] starts...\n" if($DEBUG);
			$config{$section}={} if(!defined $config{$section});
			next; 
		}
		if ( !$section ) {
			print "No section defined at line '$line'\n";
			exit 3;
		}
		chomp $line; # remove trailing \n
		if( $line =~ /^\s*([^\s=]+)\s*=\s*(.*?)\s*$/ ) {
			$val = $2;
			$key = lc $1;
			$val = 0 if($val eq 'no' or $val eq 'false');
			$val = 1 if($val eq 'yes' or $val eq 'true');
			print "Section [$section], key [$key] = '$val'\n" if($DEBUG>1);
			$val =~ s/([^\\])\\n/\1\n/g;
			$val =~ s/([^\\])\\t/\1\t/g;
			$val =~ s/\\(.)/\1/g;
			$config{"$section:$key"} = $val; # historical
			$config{$section}{$key} = $val;
		} elsif( $line =~ /^\s*!([^\s]+)/ ) {
			$key = lc $1;
			print "Section [$section], key [$key] = false\n" if($DEBUG>1);
			$config{"$section:$key"} = 0; # historical
			$config{$section}{$key} = 0;
		} elsif( $line =~ /^\s*([^\s]+)/ ) {
			print "Section [$section], key [$key] = true\n" if($DEBUG>1);
			$config{"$section:$key"} = 1; # historical
			$config{$section}{$key} = 1;
		} else {
			print "Line format not recognised: '$line'\n";
			exit 3;
		}
	}
	print "Configuration file read in.\n" if($DEBUG);
	close CFG;
}
sub initialise_tt() {
	return if($tt);
	do_log(2,"Initialising TT2 subsystem");
	eval { 
		require Template; 
	};
	if($@) {
		do_log(0, "In order to output configuration files, the Template Toolkit module\nis required.\n$@");
		exit 2;
	}
	$tt = Template->new({
		INCLUDE_PATH => "$Bin/tt2:$Bin/../tt2:$Bin/../lib/tt2"
			.($config{global}{tt2_lib}?":".$config{global}{tt2_lib}:""),
		VARIABLES => { 
			config => \%config, 
			servicedesc => \%servicedesc,
			rrdfiles => \%rrdfiles,
			virtualcenter => $config{vmware}{server}, # yanks/aussies
			virtualcentre => $config{vmware}{server}, # poms/kiwis
			bin => $Bin,
		},
		# EVAL_PERL => 1, # maybe not...
	});
	if(!$tt) {
		do_log(0, "Unable to initialise Template Toolkit.\n".$Template::ERROR);
		exit 2;
	}
}
sub vmware_disconnect() {
	do_log(0,"Disconnecting from VMware.");
	eval { $vmware->logout(); };
	if( $@ ) {
		do_log(0,"Logging out from VMware failed: $@");
	}
}
sub vmware_connect() {
	eval { 
		alarm( $config{'global'}{'timeout'} );
		$vmware->login( 
			user_name => $config{'vmware'}{'username'},
			password => $config{'vmware'}{'password'},
		);
		alarm(0);
	};
	if($@) {
		do_log(0, "Unable to authenticate to Virtual Centre server ".$config{'vmware'}{'server'}." as ".$config{vmware}{username}."\nERROR: $@");
		if( $config{'global'}{'daemon'} ) {
			do_log(0, "Sleeping 60s, then continuing");
			# Why is eval necessary? Because sleep() uses SIGALRM.
			eval { sleep(60); };
		} else {
			exit 1;
		}
	}
}
# Obtain nagios thresholds for a given item
sub threshold($$@) {
	my($thresh,$type,@sections) = @_;
	my($key) = "thresh_${thresh}_${type}";

	foreach ( @sections ) {
		return( $config{$_}{$key} ) if($config{$_}{$key});
	}

	return( $config{'nagios'}{$key} ) if($config{'nagios'}{$key});
	return 0;
}

# Get a meaningful description for a device from its number
sub devdesc($$) {
	my($item,$key) = @_;
	my $device;
	return $item->{devices_desc}{$key} if($item->{devices_desc}{$key});
	$device = $item->config->hardware->device->[$key];
	return $key if(!$device);
	return $device->deviceInfo->label;
}

# Obtain vc perfcounter information
sub getcounters($) {
    my($type) = $_[0];
    # we need to identify which counter is which
    my $perfCounterInfo = $perfmgr->perfCounter;
    do_log(2,"Identifying perfcounter IDs");
    foreach ( @$perfCounterInfo ) {
        next if($_->groupInfo->key !~ /$type/); # optimise
        if($_->rollupType->val =~ /average|summation|latest/) {
        	do_log(4,$_->groupInfo->key.":".$_->nameInfo->key);
            $perfkeys{$_->groupInfo->key.":".$_->nameInfo->key}=$_->key;
            $perfkeys{$_->key} = $_->groupInfo->key.":".$_->nameInfo->key;
        }
    }
}
sub getinterval() {
    # We try to get the interval closest to 5min (the normal polling
    # interval for MRTG)
    do_log(3,"Retrieving interval data...");
    my $hi = $perfmgr->historicalInterval;
	$interval = 0;
	$intervalid = 0;
    foreach (@$hi) {
    	do_log(3," Interval = ".$_->samplingPeriod);
		if(!$interval or $_->samplingPeriod<$interval) {
        	$interval = $_->samplingPeriod ;
			$intervalid = $_->key;
		}
        if($_->samplingPeriod == 300) { 
			$interval = 300; $intervalid = $_->key; last; 
		}
    }
    do_log(2,"Selected interval is: $interval ($intervalid)");
}
sub runquery($) {
	my $qarray = $_[0];
	my $perfdata;
    do_log(3, "Retrieving data...");
    eval { $perfdata = $perfmgr->QueryPerf(querySpec => $qarray); };
    if ($@) {
        if (ref($@) eq 'SoapFault') {
            if (ref($@->detail) eq 'InvalidArgument') {
                do_log(1,"Error: $@");
                do_log(1,"Error: ".$@->detail);
                do_log(1,"Perf stats not available : Increase Perf logging level to 2 or higher.");
                return 0;
            }
        }
        my($msg) = $@; $msg =~ s/^[\n\s]*//; $msg =~ s/\n/~ /g;
        if($msg =~ /SOAP Fault/i) {
            do_log(1,"Error: $@");
            do_log(1,"Perf stats not available : Increase Perf logging level to 2 or higher.");
            return 0;
        }
       	do_log(0,"Error: $msg");
        return 0;
    }
    if(!$perfdata or ! @$perfdata) {
        do_log(1,"Perf stats not available at required interval (300s).");
        return 0;
    }
	return $perfdata;

}

sub initialise() {
	my $rv;
	readconfig();
	foreach my $opt ( @ARGV ) {
		if( $opt =~ /--(\S+):(\S+)=(.*)/ ) {
			$config{$1}{$2} = $3;
			print "Setting [$1] option '$2' to '$3'\n" if($DEBUG);
		} elsif( $opt =~ /--(\S+):(\S+)/ ) {
			$config{$1}{$2} = 1;
			print "Setting [$1] option '$2' to TRUE\n" if($DEBUG);
		} elsif( $opt =~ /--no-(\S+):(\S+)/ ) {
			$config{$1}{$2} = 0;
			print "Setting [$1] option '$2' to FALSE\n" if($DEBUG);
		} elsif( $opt =~ /--(\S+)=(.*)/ ) {
			$config{global}{$1} = $2;
			print "Setting global option '$1' to '$2'\n" if($DEBUG);
		} elsif( $opt =~ /--no-(\S+)/ ) {
			$config{global}{$1} = 0;
			print "Setting global option '$1' to FALSE\n" if($DEBUG);
		} elsif( $opt =~ /--(\S+)/ ) {
			$config{global}{$1} = 1;
			print "Setting global option '$1' to TRUE\n" if($DEBUG);
		} else {
			print "usage: $0 [cfgfile] --[section:]option=value\n";
			print "               --[section:]option\n";
			print "               --no-[section:]option\n";
			print "\nDefault [section] is [global].\n";
			print "Configuration file is $CFGFILE\n";
			exit 1;
		}
	}
	$DEBUG = $config{'global'}{'debug'} if(defined $config{'global'}{'debug'});
	print "********* DEBUG LEVEL $DEBUG ****************\n" if($DEBUG);
	if( $config{'global'}{'includelib'} ) {
		do_log(2,"Adding perl libpath: ".$config{'global'}{'includelib'});
		push @INC, split /:/,$config{'global'}{'includelib'};
	}
	if(! defined $config{'global'}{'daemon'} ) {
		if($DEBUG) {
			$config{'global'}{'daemon'} = 0;
		} else {
			$config{'global'}{'daemon'} = 1;
		}
	}
	# Special initialisation for syslog connector
	if( $config{'syslog'}{'enable'} ) {
		do_log(2, "Initialising syslog connector" );
		eval { require Sys::Syslog; };
		if($@) {
			do_log(0, "Unable to load Sys::Syslog module.\n$@");
			exit 2;
		}
		eval {
			Sys::Syslog::openlog( 'vmware-agent', 'ndelay', $config{'syslog'}{'facility'} );
		};
		if($@) {
			do_log(0, "Unable to open Syslog socket:\n$@");
			exit 2;
		}
		Sys::Syslog::syslog( "info", "VMware agent enabled Syslog connector" );
		$has_syslog = 1;
	}
	# Special initialisation for  File connector
	if( $config{'logfile'}{'enable'} ) {
		do_log(2,"Initialising logfile connector to ".$config{'logfile'}{'file'});
		eval { require POSIX; };
		if($@) {
			do_log(0,"Unable to load POSIX module: cannot use logfile output\n$@");
			exit 2;
		}
		my $openarg = "";
		if( ! $config{'logfile'}{'file'} ) {
			do_log(0, "You must specify an output file in order to use the 'logfile' connector");
			exit 2;
		}
		if( $config{'logfile'}{'append'} ) {
			$openarg = ">>".$config{'logfile'}{'file'};
		} else {
			$openarg = ">".$config{'logfile'}{'file'};
		}
		open LOGFILE,$openarg or do {
			do_log(0,"Unable to open logfile '".$config{'logfile'}{'file'}."'\n$!");
			exit 2;
		};
		print LOGFILE "---- Opening logfile ".localtime()."\n";
		$has_logfile = 1;
		select LOGFILE; $|=32; select stdout;
	}
	# special initialisation for Nagios
	if( $config{'nagios'}{'enable'} ) {
		if( ! $config{'nagios'}{'livestatus'} ) {
			do_log(0, "To use the Nagios output module, you MUST specify the location of the\nlivestatus service in the configuration file.");
			exit 2;
		}
		do_log(2, "Initialising Nagios connector to ".$config{'nagios'}{'livestatus'});
		eval { require Monitoring::Livestatus; };
		if($@) {
			do_log(0,"Unable to load Monitoring::Livestatus module.\n$@");
			exit 2;
		}
		$livestatus = Monitoring::Livestatus->new(
			peer=>$config{'nagios'}{'livestatus'}, keepalive=>1,
			errors_are_fatal=>0, warnings=>0,
		);
		my $count = $livestatus->selectscalar_value("GET hosts\nStats: state = 0");
		if( $Monitoring::Livestatus::ErrorCode ) {
			do_log(0, "Unable to connect to livestatus service on "
				.$config{'nagios'}{'livestatus'}."\n"
				.$Monitoring::Livestatus::ErrorMessage);
			exit 2;
		}
		do_log(3, "Nagios livestatus server has $count hosts in a running state");
		if( $config{'nagios'}{'duplivestatus'} ) {
			do_log(2,"Initialising duplicate Nagios connector to ".$config{'nagios'}{'duplivestatus'});
			$duplivestatus = Monitoring::Livestatus->new(
				peer=>$config{'nagios'}{'duplivestatus'}, keepalive=>1,
				errors_are_fatal=>0, warnings=>0,
			);
			if( $Monitoring::Livestatus::ErrorCode ) {
				do_log(0, "Unable to connect to duplicate livestatus service on "
					.$config{'nagios'}{'duplivestatus'}."\n"
					.$Monitoring::Livestatus::ErrorMessage);
			}
		}

		if( $config{'nagios'}{'log_hostname'}
			and $config{'nagios'}{'log_servicedesc'} ) {
			$has_naglog = 1;
			do_log(2,"Nagios status logging enabled.");
		}
		if( 
			($config{'nagios'}{'tt2_datacenter'} and $config{'nagios'}{'cfg_datacenter'} )
			or ($config{'nagios'}{'tt2_cluster'} and $config{'nagios'}{'cfg_cluster'} )
			or ($config{'nagios'}{'tt2_host'} and $config{'nagios'}{'cfg_host'} )
			or ($config{'nagios'}{'tt2_guest'} and $config{'nagios'}{'cfg_guest'} )
		) {
			initialise_tt();
		}
	}
	# Special initialisation for MRTG connector
	if( $config{'mrtg'}{'enable'} ) {
		if( ! $config{'mrtg'}{'rrdcached'} ) {
			do_log(0, "To use the MRTG output module, you MUST specify the location of the\nrrdcached service in the configuration file.");
			exit 2;
		}
		do_log(2, "Initialising MRTG connector to ".$config{'mrtg'}{'rrdcached'});
		if( $config{mrtg}{persistent} ) {
			do_log(3, "We do not require RRDs.pm for persistent connections.");
			$config{'mrtg'}{'create'} = 1
				if(! defined $config{'mrtg'}{'create'});
			if($config{'mrtg'}{'create'}) {
				$rv = send_mrtg("HELP");
				if($rv !~ /CREATE/) {
					do_log(0, "rrdcached server does not support CREATE command.  Disabling 'create' option.");
					$config{'mrtg'}{'create'} = 0;
				} else {
					do_log(2, "rrdcached server supports CREATE.  Good!");
				}
			}
			
		} else {
			eval { require RRDs; };
			if($@) {
				do_log(0, "Unable to load RRDs.pm module: cannot use MRTG output.\n$@");
				exit 2;
			}
			if( $RRDs::VERSION < 1.4 ) {
				do_log(0, "RRD version 1.4 or later required for rrdcached support.\nYou have version ".$RRDs::VERSION." installed.");
				exit 2;
			}
			if( !defined $config{'mrtg'}{'create'} ) {
				if( $RRDs::VERSION > 1.4999 ) {
					$config{'mrtg'}{'create'} = 1;
				} else {
					$config{'mrtg'}{'create'} = 0;
				}
			}
			if( $config{'mrtg'}{'create'} and $RRDs::VERSION < 1.4999 ) {
				do_log(0, "You have specified to create RRD files, but your version of RRDtool\ndoes not support this.  Upgrade to 1.4.trunk or later, or disable create.\nDisabling create option and continuing...");
				$config{'mrtg'}{'create'} = 0;
			}
		}
		if( 
			($config{'mrtg'}{'tt2_datacenter'} and $config{'mrtg'}{'cfg_datacenter'} )
			or ($config{'mrtg'}{'tt2_cluster'} and $config{'mrtg'}{'cfg_cluster'} )
			or ($config{'mrtg'}{'tt2_host'} and $config{'mrtg'}{'cfg_host'} )
			or ($config{'mrtg'}{'tt2_guest'} and $config{'mrtg'}{'cfg_guest'} )
		) {
			initialise_tt();
		}
	}
	if( ! $config{'global'}{'frequency'} ) {
		if( $config{'global'}{'daemon'} ) {
			do_log( 1, "WARNING: You are running in daemon mode with no frequency defined.\nThis will poll at maximum rate possible!");
		}
	}
	
	# Now connect to VMware, if we can
	# Note we dont use Util::connect as this takes control of your ARGV :(
	if( ! $config{'vmware'}{'server'} or ! $config{'vmware'}{'username'}
		or ! $config{'vmware'}{'password'} ) {
		do_log(0, "Cannot connect to Virtual Centre: you must specify a server, username\nand password in the config file.");
		exit 1;
	}	
	do_log(2, "Initialising VMware connector to ".$config{'vmware'}{'server'});
	$vmware = Vim->new(
		service_url => 'https://'.$config{'vmware'}{'server'}.'/sdk/vimService.wsdl',
	);
	if(!$vmware) {
		do_log(0, "Unable to connect to Virtual Centre server ".$config{'vmware'}{'server'});
		exit 1;
	}
	vmware_connect();
	$si_view = $vmware->get_service_instance();
	do_log(2, "Virtual Centre Time : ". $si_view->CurrentTime());
	$sc_view = $vmware->get_service_content();
    $perfmgr = $vmware->get_view(mo_ref=>$sc_view->perfManager);
	getinterval();
	getcounters('cpu|net|virtualDisk|disk|mem'); # optimise: many are now in the quickstats

	return if($DEBUG<4);
	require Data::Dumper;
	$Data::Dumper::Sortkeys = 1;
	$Data::Dumper::Deepcopy = 1;
	$Data::Dumper::Indent = 1; # fixed amount
	print Dumper($si_view);

}

sub write_pidfile() {
	return if(! $config{'global'}{'pidfile'} );
	open PIDFILE, ">".$config{'global'}{'pidfile'} or do {
		do_log(1,"Unable to write pidfile ".$config{'global'}{'pidfile'}
			."\n$!");
		return;
	};
	print PIDFILE "$$\n";
	close PIDFILE;
}
#############################################################################
# Fetch all data from sources

sub identify($$);
my(%viewcache);
sub clearviewcache() {
	%viewcache = ();
}
sub getview($) {
	my($moref) = $_[0];
	my($view);
	return undef if(!$moref);
	do_log(4,"getview() given argument of type ".(ref $moref));
	return $viewcache{$moref->{type}.$moref->{value}} 
		if(defined $viewcache{$moref->{type}.$moref->{value}});
	do_log(4,"Retrieving view for MOREF=".$moref->{value});
	eval { $view = $vmware->get_view(mo_ref=>$moref); };
	$viewcache{$moref->{type}.$moref->{value}} = $view if($view);
	do_log(4,"getview() returning argument of type ".(ref $view));
	return $view;
}
sub find_entity_views {
	my(%opts) = @_;
	my($t,$views);
	my($item,$moref);
	do_log(3,"Retrieving views for entity type '".$opts{view_type}."'");
	$views = undef;
	$t = time;
	eval {
		alarm( $config{'global'}{'timeout'} );
		$views =  $vmware->find_entity_views(%opts);
		alarm(0);
	};
	if($@) {
		do_log(0,"Error querying vmware API: $@");
		vmware_disconnect();
		vmware_connect();
		return undef;
	}
	$t = time - $t;
	do_log(2,"VC API took $t seconds to retrieve ".($#$views+1)." ".$opts{view_type}." item(s).");

	# Load them into the cache!
	foreach $item ( @$views ) {
		$moref = $item->{mo_ref};
		next if(!$moref);
		$viewcache{$moref->{type}.$moref->{value}} = $item;
	}
	return $views;
}
# Find the parent datacenter
sub find_parent($$) {
	my($type,$moref) = @_;
	my($view);
	return undef if(!$moref);
	if( ref $moref eq 'VirtualMachine' ) {
		$moref = $moref->resourcePool();
	}
	if( ref $moref ne 'ManagedObjectReference' ) {
		$moref = $moref->parent(); # oops we were passed a view, not a moref!
	}
	do_log(3,"Finding parent of type $type on Moref=".$moref->{type}.":".$moref->{value});
	while($moref and ($moref->{type} ne $type) and $moref->{value}) {
		$view = getview($moref);
		if($view) {
			if($moref->{type} eq 'ResourcePool') {
				$moref = $view->owner();
			} else {
				$moref = $view->parent();
			}
		} else { last; }
	};
	if( $moref and $moref->{type}) {
		return getview($moref);
	} else {
		return undef;
	}
}
sub find_datacenter($) {
	return find_parent('Datacenter',$_[0]);
}
sub find_cluster($) {
	return find_parent('ClusterComputeResource',$_[0]);
}
sub find_vms($) {
	my($moref) = @_;
	my($view,@views,$vp);
	my($t);
	@views = ();
	return \@views if(!$moref);
	if( ref $moref eq 'ARRAY' ) {
		do_log(3,"- Finding VMs on an array");
		foreach ( @$moref ) {
			do_log(3,"- Recursing through array");
			$vp = find_vms($_);
			push @views, @$vp;
			return \@views;
		}
	} elsif( ref $moref eq 'VirtualMachine' ) {
		do_log(3,"- Returning the VM object");
		push @views, $moref;
		return \@views;
	} elsif( ref $moref eq 'ManagedObjectReference' ) {
		do_log(3,"- Finding VMs on Moref=".$moref->{type}.":".$moref->{value});
		$view = getview($moref);
	} elsif( ref $moref eq '' ) {
		do_log(1,"- find_vms Received a scalar! '$moref'");
		return \@views;
	} else {
		# we were passed a view, not a moref!
		$view = $moref;
		do_log(3,"- Finding VMs on a view type ".(ref $view));
	}
	$t = ref $view;
	if( $t eq 'Datacenter' ) {
		do_log(3,"- Recursing into vmFolder");
		$vp = find_vms($view->vmFolder);
		push @views, @$vp;
	} elsif( $t eq 'VirtualMachine' ) {
		do_log(3,"- Returning this VM");
		push @views, $view;
		return \@views;
	} elsif( $t eq 'Folder' ) {
		do_log(3,"- Looping through childEntity");
		foreach my $child ( $view->childEntity ) {
			foreach ( @$child ) {
				if( ref $_ eq 'VirtualMachine' ) {
					do_log(4,"- Adding a VM");
					push @views, $_;
				} elsif( $_->{type} eq 'VirtualMachine' ) {
					do_log(4,"- Looking up a VM and adding");
					push @views, getview($_);
				} else {
					do_log(3,"- Recursing on type ".$_->{type});
					$vp = find_vms($_);
					push @views, @$vp;
				}
			}
		}
	} elsif( $t eq 'ClusterComputeResource' ) {
		foreach my $child ( $view->resourcePool ) {
			do_log(3,"- Recursing on resource pool ".(ref $child));
			$vp = find_vms($child);
			push @views, @$vp;
		}
	} elsif( $t eq 'ResourcePool' ) {
		my $vmp = $view->vm;
		if($vmp) {
			do_log(3,"- Added my own list of VMs");
			foreach $moref ( @$vmp ) {
				push @views, getview($moref);
			}
		}
		foreach my $child ( $view->resourcePool ) {
			do_log(3,"- Recursing on resource pool ".(ref $child));
			$vp = find_vms($child);
			push @views, @$vp;
		}
	} elsif( $t eq 'HostSystem' ) {
		my $vmp = $view->vm;
		if($vmp) {
			do_log(3,"- Added my own list of VMs");
			foreach $moref ( @$vmp ) {
				push @views, getview($moref);
			}
		}
	}
	return \@views;
}
sub clear_data() {
	clearviewcache();
	$datacenters = [];
	$clusters = [];
	$hosts = [];
	$guests = [];
	%ntp = ();
	%cfghosts = ();
}
sub fetch_data() {
	clear_data();
	do_log(2,"Fetching VMware data");
	if( $config{'global'}{'datacenters'} ) {
		do_log(3,"Fetching VMware datacentre data");
		$datacenters = find_entity_views(view_type=>'Datacenter');
		if($datacenters and !@$datacenters ) { # There MUST be at least one!
			vmware_disconnect();
			vmware_connect();
		}
		# collect datastore details?
	}
	if( $config{'global'}{'clusters'} ) {
		do_log(3,"Fetching VMware cluster data");
		$clusters = find_entity_views(view_type=>'ClusterComputeResource');
		if(!$clusters) {
			vmware_disconnect();
			vmware_connect();
		}
		# collect datastore details?
	}
	if( $config{'global'}{'hosts'} ) {
		my $qstart;
		do_log(3,"Fetching VMware host data");
		$hosts = find_entity_views(view_type=>'HostSystem');
		if(!$hosts) {
			vmware_disconnect();
			vmware_connect();
		}

		# Collect NTP status
		if( $config{'nagios'}{'ntp'} and $config{'nagios'}{'enable'} and $hosts) {
			%ntp = ();
			eval {
				require Net::NTP;
			};
			if($@) {
				do_log(0,"Net::NTP module not installed!");
			} else {
				do_log(2,"Fetching VMware host NTP status");
				foreach my $item ( @$hosts ) {
					my($fn,$na) = identify($item,0);
					my($t);
					my %rv;
					$Net::NTP::TIMEOUT=2;
					eval {
						%rv = Net::NTP::get_ntp_response($fn);
					};
					if($@) {
						do_log(1,"$na: $@");
					} elsif(! $rv{'Transmit Timestamp'} ) {
						do_log(3,"$na: Unable to retrieve time");
					} else {
						$t = $rv{'Transmit Timestamp'};
						$ntp{$na} = int(100*($t - time()))/100;
						do_log(3,"$na: ".localtime($t));
					}
				}
			}
		}

		# collect datastore details
		# may also need to retrieve perf stats here
		# XXX to be written

		do_log(3,"Building VMware host perf counter queries");
		my @queries = ();
        my (@t) = gmtime(time-$interval); # 5 mins ago
        my $start = sprintf("%04d-%02d-%02dT%02d:%02d:00Z",
          (1900+$t[5]),(1+$t[4]),$t[3],$t[2],$t[1]);
        @t = gmtime(time);
        my $end   = sprintf("%04d-%02d-%02dT%02d:%02d:00Z",
            (1900+$t[5]),(1+$t[4]),$t[3],$t[2],$t[1]);
        do_log(3,"Start time: $start\nEnd time  : $end\n");
		my %results = ();
		foreach my $item ( @$hosts ) {
		  my @metricids = ();
		  my $perfquery;
		  my @net = ();
		  my @hd = ();
		  my %devdesc = ();

          foreach my $k ( qw/mem:swapoutRate mem:swapinRate net:usage disk:usage/ ) {
                if(defined $perfkeys{$k}) {
                    push @metricids, PerfMetricId->new (
                        counterId => $perfkeys{$k}, instance => ''
					);
           		} else {
					do_log(3,"There are no stats available for $k");
                }
				$item->{$k} = 0;
		    	$results{$item->{mo_ref}{value}.":".$perfkeys{$k}} = 0;
		  }

		  # now we have the list of metrics for this vhost
          $perfquery = PerfQuerySpec->new(entity => $item,
            metricId => \@metricids, intervalId => $interval,
            startTime => $start, endTime => $end );
          push @queries,$perfquery;
		}
		# Now we have to run the queries
		do_log(3,"Running VMware host perf counter queries");
		$qstart = time;
		my $perfdata = runquery( \@queries );
		do_log(3,"Query took ".(time-$qstart)."sec");
		if($perfdata) {
			do_log(3,"Processing VMware host perf counter query results");

			foreach my $pd (@$perfdata) { # one per host
		        my $time_stamps = $pd->sampleInfo;
		        my $values = $pd->value;
		        next if(!$time_stamps or !$values);
		        my $nval = $#$time_stamps;
		        next if($nval<0);
				my $entity = $pd->entity->{value};  # moref
				my $item = getview($pd->entity);

				do_log(3,"Perfdata object: ".($item->name)."($entity) ".$time_stamps->[$nval]->timestamp);
		        foreach my $v (@$values) { # one per metric/instance
					my $k = $entity.":".$v->id->counterId;
					if($v->id->instance) {
						$k .= ":".$v->id->instance;
	            		$results{$k} = $v->value->[$nval]; # per-instance
					} else {
	            		$results{$k} = $v->value->[$nval]; # per-host
					}
		            do_log(3, $item->name." $k".($v->id->instance?('('.$v->id->instance.')'):'').' ['.$perfkeys{$v->id->counterId}."] = ".$v->value->[$nval]);
				}

			}

			# Then put them into the hosts array
			foreach my $item ( @$hosts ) {
              foreach my $k ( qw/mem:swapoutRate mem:swapinRate net:usage disk:usage/ ) {
			    $item->{$k} = $results{$item->{mo_ref}{value}.":".$perfkeys{$k}};
				do_log(3,$item->name." $k = ".$item->{$k});
			  }
			}
		} else {
			do_log(1,"VMware host perf counter retrieval failed!");
		}
	}
	if( $config{'global'}{'guests'} ) {
		my $qstart;
		do_log(3,"Fetching VMware guest data");
		$guests = find_entity_views(view_type=>'VirtualMachine');
		if(!$guests) {
			vmware_disconnect();
			vmware_connect();
		}
		# Define the perf queries we need to run, and their time window
		do_log(3,"Building VMware guest perf counter queries");
		my @queries = ();
        my (@t) = gmtime(time-$interval); # 5 mins ago
        my $start = sprintf("%04d-%02d-%02dT%02d:%02d:00Z",
          (1900+$t[5]),(1+$t[4]),$t[3],$t[2],$t[1]);
        @t = gmtime(time);
        my $end   = sprintf("%04d-%02d-%02dT%02d:%02d:00Z",
            (1900+$t[5]),(1+$t[4]),$t[3],$t[2],$t[1]);
        do_log(3,"Start time: $start\nEnd time  : $end\n");
		my %results = ();
		foreach my $item ( @$guests ) {
		  next if(!$item->runtime or $item->runtime->powerState->val ne 'poweredOn');
		  my @metricids = ();
		  my @curmetricids = ();
		  my $maxcpu = $item->config->hardware->numCPU;
		  my $perfquery;
		  my @net = ();
		  my @hd = ();
		  my %devdesc = ();
		  foreach my $k ( @{$item->config->hardware->device} ) {
			if( $k->deviceInfo->label =~ /^SCSI c/ ) {
				$devdesc{$k->key} = "scsi".$k->busNumber;
			} elsif( $k->deviceInfo->label =~ /^Hard/ ) {
				push @hd,$k->key;
				$devdesc{$k->key} = $devdesc{$k->controllerKey}.':'.$k->unitNumber;
			} elsif( $k->deviceInfo->label =~ /^Network/ ) {
				push @net,$k->key;
				$devdesc{$k->key} = $k->deviceInfo->label;
#			} else {
#				$devdesc{$k->key} = $k->deviceInfo->label;
			}
		  }
		  $item->{devices_hd} = [ @hd ];
		  $item->{devices_net} = [ @net ];
		  $item->{devices_desc} = \%devdesc;
          # CPU items
          foreach my $k ( qw/cpu:used cpu:ready cpu:system cpu:wait/ ) {
            # We're asking for data for all vCPUs, although probably only
            # 1 of them will actually be there and return data.
            if(defined $perfkeys{$k}) {
            	foreach my $vcpu ( 1..$maxcpu ) {
                    push @metricids, PerfMetricId->new (
                        counterId => $perfkeys{$k}, instance => ($vcpu-1)) ;
                }
           	} else {
				do_log(3,"There are no stats available for $k");
            }
		    $results{$item->{mo_ref}{value}.":".$perfkeys{$k}} = 0;
          }
          # Standalone items
          foreach my $k ( qw/mem:swapoutRate mem:swapinRate net:usage disk:usage/ ) {
                if(defined $perfkeys{$k}) {
                    push @metricids, PerfMetricId->new (
                        counterId => $perfkeys{$k}, instance => ''
					);
           		} else {
					do_log(3,"There are no stats available for $k");
                }
		    	$results{$item->{mo_ref}{value}.":".$perfkeys{$k}} = 0;
		  }
          # Per net interface items
          foreach my $k ( qw/net:usage net:transmitted net:received/ ) {
            if(defined $perfkeys{$k}) {
				foreach (@net) {
					# Network interface stats are indexed by device number
                    push @metricids, PerfMetricId->new (
                        counterId => $perfkeys{$k}, instance => $_
					);
		    		$results{$item->{mo_ref}{value}.":".$perfkeys{$k}.":$_"} = 0;
				}
            } else {
				do_log(3,"There are no stats available for $k");
            }
		  }
          # per dirtual disk items
          foreach my $k ( qw/virtualDisk:read virtualDisk:write virtualDisk:totalReadLatency virtualDisk:totalWriteLatency/ ) {
            if(defined $perfkeys{$k}) {
				foreach ( @hd ) {
					# Hard disk stats are indexed by device NAME instead of number. Argh!
                    push @curmetricids, PerfMetricId->new (
                        counterId => $perfkeys{$k}, instance => $devdesc{$_}
					);
		    		$results{$item->{mo_ref}{value}.":".$perfkeys{$k}.":".$devdesc{$_}} = 0;
				}
            } else {
				do_log(3,"There are no stats available for $k");
			}
		  }
		  # now we have the list of metrics for this vhost
          $perfquery = PerfQuerySpec->new(entity => $item,
            metricId => \@metricids, intervalId => $interval,
            startTime => $start, endTime => $end );
          push @queries,$perfquery;
          $perfquery = PerfQuerySpec->new(entity => $item,
            metricId => \@curmetricids, intervalId =>$interval, # live data
            startTime => $start, endTime => $end );
          push @queries,$perfquery;
        }
		# Now we have to run the queries
		do_log(3,"Running VMware guest perf counter queries");
		$qstart = time;
		my $perfdata = runquery( \@queries );
		do_log(3,"Query took ".(time-$qstart)."sec");
		if($perfdata) {
			do_log(3,"Processing VMware guest perf counter query results");

			foreach my $pd (@$perfdata) { # one per host
		        my $time_stamps = $pd->sampleInfo;
		        my $values = $pd->value;
		        next if(!$time_stamps or !$values);
		        my $nval = $#$time_stamps;
		        next if($nval<0);
				my $entity = $pd->entity->{value}; # moref
				my $n = getview($pd->entity)->guest->hostName;
				do_log(3,"Perfdata object: $n ($entity) ".$time_stamps->[$nval]->timestamp);
		        foreach my $v (@$values) { # one per metric/instance
					my $k = $entity.":".$v->id->counterId;
		            do_log(3, "$n($entity) ".$v->id->counterId.($v->id->instance?('('.$v->id->instance.')'):'').' ['.$perfkeys{$v->id->counterId}."] = ".$v->value->[$nval]);
					if($perfkeys{$v->id->counterId}=~/^cpu:/) {
	            		$results{$k} += $v->value->[$nval]; # total over all cpus
					} elsif($v->id->instance) {
						$k .= ":".$v->id->instance;
	            		$results{$k} = $v->value->[$nval]; # per-instance
					} else {
	            		$results{$k} = $v->value->[$nval]; # per-host
					}
		            #do_log(3, "$n($entity) $k = ".$results{$k});
		        }
			}
	
			# now, we need to turn cpu counters into percentages.
			# they are now in milliseconds total over all processors
			# so divide by # procs, and divide by time interval in ms.
			foreach my $item ( @$guests ) {
			  my($host,$hostcpuspeed,$max)=(0,0,0);	
			  next if(!$item->runtime or $item->runtime->powerState->val ne 'poweredOn');
			  $max = $item->config->hardware->numCPU
				* $item->config->hardware->numCoresPerSocket
				* $interval * 1000; # milliseconds in interval (should be 300,000 but might be 20,000)
			  next if(!$max);
			  do_log(3,"Guest ".$item->name." max=$max interval=$interval");
			  # now, store them against the guest for later retrieval
		      foreach my $k ( qw/cpu:used cpu:ready cpu:system cpu:wait/) {
				my $metricid = $perfkeys{$k};
			    $item->{$k} = 
					($results{$item->{mo_ref}{value}.":".$metricid} / $max) * 100.0;
				do_log(3,$item->name." $k = "
					.$results{$item->{mo_ref}{value}.":".$metricid}." = "
					.$item->{$k}.'%');
			  }
              foreach my $k ( qw/mem:swapoutRate mem:swapinRate net:usage disk:usage/ ) {
			    $item->{$k} = $results{$item->{mo_ref}{value}.":".$perfkeys{$k}};
				do_log(3,$item->name." $k = ".$item->{$k});
			  }
        	  foreach my $k ( qw/net:usage net:transmitted net:received/ ) {
				foreach my $netdev ( @{$item->{devices_net}} ) {
					$item->{"$k:$netdev"} = $results{$item->{mo_ref}{value}.":".$perfkeys{$k}.":$netdev"};
					do_log(3,$item->name." $k($netdev) = ".$item->{"$k:$netdev"});
				}
			  }
        	  foreach my $k ( qw/virtualDisk:read virtualDisk:write virtualDisk:totalReadLatency virtualDisk:totalWriteLatency/ ) {
				foreach my $hddev ( @{$item->{devices_hd}} ) {
					$item->{"$k:$hddev"} = $results{$item->{mo_ref}{value}.":".$perfkeys{$k}.":".$item->{devices_desc}{$hddev}};
					do_log(3,$item->name." $k($hddev) = ".$item->{"$k:$hddev"});
				}
			  }

			}

		} else {
			do_log(1,"VMware perf counter retrieval failed!");
		}
	}
}
# Count the child VMs and their statuses.
# Will this result in the VM objects being retrieved twice or more? Inefficient?
sub count_vms($) {
	my($item) = $_[0];
	my($tot,$up) = (0,0);
	my($v);

	do_log(3,"Counting VMs under ".$item->name);
	if(!$item) {
		do_log(1,"Something is wrong - I have a null item!");
		return (undef,undef);
	}
	$v = find_vms($item);
	if(!$v) {
		do_log(1,"Unable to find any VMs defined under ".$item->name);
		return (undef,undef);
	}

	foreach my $vm ( @$v ) {
		next if(!$vm);
		if(ref $vm eq 'VirtualMachine') {
			$tot += 1;
			$up += 1 if($vm->runtime and $vm->runtime->powerState->val eq 'poweredOn');
			do_log(4,"  This one is ".$vm->runtime->powerState->val)
				if($vm->runtime);
		} elsif( ! ref $vm ) {
			do_log(0,"Problem: find_vms() returned a constant '$vm'");
		} else {
			do_log(0,"Problem: find_vms() returned an object type ".(ref $vm));
		}
	}
	do_log(3,"Found $tot VMs under ".$item->name." ($up up)");
	return ($tot,$up);
}

sub canonicalise($) {
	my($h) = $_[0];
	my($ip);
	my($ch);
	$ip = gethostbyname($h);
	return $h if(!$ip);
	$ch = gethostbyaddr($ip,AF_INET);
	return $h if(!$ch);
	do_log(4,"Host: $h IP: ".inet_ntoa($ip)." Canon: $ch");
	return $ch;
}
# These identify the true name of a guest from the guest view.
my(%idcache) = ();
sub identify($$) {
	# identify a hostname in Nagios
	my($view,$verify) = @_;
	my($full,$real); # hostName, ipAddress, net[n].ipAddress
	my($trim) = $config{nagios}{stripdomain};
	my($count,$uuid);
	my($ipaddr,@ipaddr);
	my(@rv);
	my(%tried) = ();

	$trim =~ s/\./\\./g;

	# First, check against hostname
	do_log(3,"identify(): Identifying item of type [".(ref $view)."]".((ref $view)?" moid=".$view->{mo_ref}->{value}:""));
	if(!ref $view) {
		$real = $view;
	} elsif( ref $view eq 'HostSystem' ) {
		do_log(3,"identify(): Host is ".$view->name);
		$real = $view->name;
	} elsif( $view->guest->hostName and $view->guest->hostName=~/\./ ) {
		do_log(3,"identify(): Guest is ".$view->name);
		$uuid = $view->config->uuid;
		if( defined $idcache{$uuid} ) {
			return @{$idcache{$uuid}};
		}
		$real = $view->guest->hostName;
	} else {
		$real = ""; # not known yet
	}
	$full = lc $real;
	if($real and $real=~/\./) {
		if($config{nagios}{canonicalise}) {
			$real = canonicalise($real);
		}
		$real = lc $real if($config{nagios}{tolower});
		$real =~ s/\.$trim$// if($trim);
		if($verify and $livestatus) {
			$count = $livestatus->selectscalar_value("GET hosts\nFilter: host_name = $real");
			do_log(4,"identify(): Verifying [$full] as [$real] gives [$count]");
			do_log(($config{nagios}{verify_warning}?1:3),
				"identify(): Could not find [$real] in livestatus.")
				if(!$count);;
		}
		if($count or !$verify) {
#			$uuid = $view->config->uuid if(!$uuid);
			$idcache{$uuid} = [ $full, $real ]
				if( $uuid and (ref $view eq 'VirtualMachine'));
			do_log(3,"identify(): Identified host $full as $real (by vmware Tools hostName)");
			return ($full,$real);
		}
		$tried{$real} = 1;
	}
	if(!ref $view) {
		return(undef,undef);
	}
	# Next, check against IP addresses
	if( ref $view eq 'VirtualMachine' ) {
		push @ipaddr, $view->guest->ipAddress;
		if( $view->guest->net ) {
			foreach my $net ( @{$view->guest->net} ) {
				next if(!$net or !ref $net);
				if( ref $net->ipAddress eq 'ARRAY' ) {
					foreach $ipaddr ( @{$net->ipAddress}  ) {
						do_log(3,"identify(): Extracting ipAddress from net array...($ipaddr)");
						push @ipaddr,$ipaddr;
					}
				} else {
					push @ipaddr,$net->ipAddress;
					do_log(3,"identify(): Extracting ipAddress from net...(".$net->ipAddress.")");
				}
			}
		}
			
		foreach $ipaddr ( @ipaddr ) {
			next if(!$ipaddr);
			do_log(3,"identify(): Testing IP [$ipaddr]");
			@rv	= gethostbyaddr(inet_aton($ipaddr),AF_INET);
			next if(!@rv);
			$real = $rv[0];		
			next if(!$real);
			$full = lc $real;
			$real = $full if($config{nagios}{tolower});
			$real =~ s/\.$trim$// if($trim);
			next if(!$real);
			next if($tried{$real});
			$tried{$real} = 1;
			if($verify and $livestatus) {
				$count = $livestatus->selectscalar_value("GET hosts\nFilter: host_name = $real");
				do_log(4,"identify(): Verifying [$ipaddr] as [$real] gives [$count]");
				do_log(($config{nagios}{verify_warning}?1:3),
					"identify(): Could not find [$real] in livestatus (from IP addr $ipaddr).")
					if(!$count);;
				last if($count);
			} else {
				last;
			}
		}
		if(($count or !$verify) and $full and $real) {
			$idcache{$uuid} = [ $full, $real ]
				if( $uuid and (ref $view eq 'VirtualMachine'));
			do_log(3,"identify(): Identified host ".$view->name." as $real (by vmware Tools ipAddress)");
			return ($full,$real);
		}
	} # virtual machines only

	if( ! $config{vmware}{usename} ) {
		return (undef,undef);
	}

	# Finally, check against the first token of the VM name
	$real = $view->name;
	$real =~ s/\s.*//;
	$full = lc $real;
	$real = $full if($config{nagios}{tolower});
	$real =~ s/\.$trim$// if($trim);
	if($real and !$tried{$real}) {
		if($config{nagios}{canonicalise}) {
			$real = canonicalise($real);
		}
		if($verify and $livestatus) {
			$count = $livestatus->selectscalar_value("GET hosts\nFilter: host_name = $real");
			do_log(4,"identify(): Verifying [".$view->name."] as [$real] gives [$count]");
			do_log(($config{nagios}{verify_warning}?1:3),
				"identify(): Could not find [$real] in livestatus (from view name ".$view->name.").")
				if(!$count);;
		}
		if($count or !$verify) {
#			$uuid = $view->config->uuid if(!$uuid);
			$idcache{$uuid} = [ $full, $real ]
				if( $uuid and (ref $view eq 'VirtualMachine'));
			do_log(3,"identify(): Identified host ".$view->name." as $real (by VM name)");
			return ($full,$real);
		}
	}
	do_log(($config{nagios}{verify_warning}?1:3),
		"identify(): Unable to identify object ".$view->name);

	return (undef,undef);
}
sub cleanup($) { # Make a name an acceptable identifier to nagios/mrtg
	my($v) = $_[0];
	$v =~ s/[^\w\.]/_/g; # this is probably overkill
	$v = lc $v;
	return $v;
}	
#############################################################################
# All update functions

sub send_nagios_status($$$$) {
	my($host,$svc,$status,$msg) = @_;
	my($t) = time();
	return if(! $config{nagios}{enable} );
	return if(!$host);
	if( $config{global}{test} ) {
		if($svc) {
			do_log(3,"NOT Sending Nagios status [$host][$svc]=$status");
		} else {
			do_log(3,"NOT Sending Nagios status [$host]=$status");
		}
		return;
	}
	if($livestatus and !$livestatuserr) {
		if($svc) {
			do_log(3,"Sending Nagios status [$host][$svc]=$status");
			$livestatus->do("COMMAND [$t] PROCESS_SERVICE_CHECK_RESULT;$host;$svc;$status;$msg");
		} else {
			do_log(3,"Sending Nagios status [$host]=$status");
			$livestatus->do("COMMAND [$t] PROCESS_HOST_CHECK_RESULT;$host;$status;$msg");
		}
	}
	if(!$livestatuserr and (!$livestatus or $Monitoring::Livestatus::ErrorCode)) {
		do_log(1, "Unable to send update to livestatus service for [$host][$svc]\n"
			.$Monitoring::Livestatus::ErrorMessage);
		$livestatus = Monitoring::Livestatus->new(
			peer=>$config{'nagios'}{'livestatus'}, keepalive=>1,
			errors_are_fatal=>0, warnings=>0,
		);
		if( $Monitoring::Livestatus::ErrorCode or !$livestatus) {
			do_log(0, "Unable to reconnect to livestatus service on "
					.$config{'nagios'}{'livestatus'}."\n"
					.$Monitoring::Livestatus::ErrorMessage);
			$livestatuserr = 1;
		} else {
			do_log(2,"Reconnected to livestatus service");
		}
	}
	return if(!$config{'nagios'}{'duplivestatus'}); # no duplicate so return
	return if($duplivestatuserr);
	if($duplivestatus) {
		do_log(3,"Sending duplicate Nagios status");
		if($svc) {
			$duplivestatus->do("COMMAND [$t] PROCESS_SERVICE_CHECK_RESULT;$host;$svc;$status;$msg");
		} else {
			$duplivestatus->do("COMMAND [$t] PROCESS_HOST_CHECK_RESULT;$host;$status;$msg");
		}
	}
	if(!$duplivestatus or $Monitoring::Livestatus::ErrorCode) {
		do_log(1, "Unable to send update to duplicate livestatus service for [$host][$svc]\n"
			.$Monitoring::Livestatus::ErrorMessage);
		$duplivestatus = Monitoring::Livestatus->new(
			peer=>$config{'nagios'}{'duplivestatus'}, keepalive=>1,
			errors_are_fatal=>0, warnings=>0,
		);
		if( $Monitoring::Livestatus::ErrorCode or !$duplivestatus ) {
			do_log(0, "Unable to reconnect to duplicate livestatus service on "
					.$config{'nagios'}{'duplivestatus'}."\n"
					.$Monitoring::Livestatus::ErrorMessage);
			$duplivestatuserr = 1; # no more tries this pass
		} else {
			do_log(2,"Reconnected to duplicate livestatus service");
		}
	}
}
# Send cmd via direct connection to rrdcached
my($rrdcached)=undef;
sub send_mrtg($) {
	my($cmd) = $_[0];
	my($rv) = undef;
	my($sin,$ip,$n);

	return if(! $config{mrtg}{enable} );
	if( $config{global}{test} ) {
		do_log(3,"NOT Sending MRTG command [$cmd]");
		return;
	}
	if(!$rrdcached) {
		my($port)=0;
		my($host) = '';
		if($config{mrtg}{rrdcached}=~/(\S+)(:(\d+))?/) {
			$port = $3;
			$host = $1;
		} else { ($host,$port)=('mrtg',42217); }
		$port=getservbyname('rrdcached','tcp') if(!$port);
		$port = 42217 if(!$port);
#		$ip = gethostbyname($host);
#		if(!$ip) {
#			do_log(0,"Bad hostname [$host] specified for rrdcached address");
#			return "-1 $!";
#		}
		do_log(2,"Connecting to rrdcached on $host:$port");
		$rrdcached = IO::Socket::INET->new(
			PeerAddr => $host,
			PeerPort => $port,
			Proto => 'tcp',
			ReuseAddr => 1,
			Timeout => $config{global}{timeout}
		);
		if(!$rrdcached) {
			do_log(0,"Unable to connect to rrdcached server on $host:$port ($rv): $!");
			return "-1 $!";
		}
		do_log(3,"Successfully connected to rrdcached on $host:$port");
	}
	# send command
	do_log(3,"Sending [$cmd] to rrdcached");

	eval {
		alarm( $config{'global'}{'timeout'} );
		print $rrdcached "$cmd\n";
		alarm(0);
	};
	if($@) {
		close $rrdcached;
		$rrdcached = 0; # force reconnect next time
		do_log(1,"Write failed to rrdcached ($cmd)");
		return "-1 write failed";
	}
	# retrieve response
	eval {
		my($n)=0;
		alarm( $config{'global'}{'timeout'} );
		$rv = <$rrdcached>;
		do_log(3,"Received: $rv");
		if($rv =~ /^(\d+)/) {
			$n = $1;
			while($n) {
				$rv .= <$rrdcached>;
				$n -= 1;
				do_log(3,"Received: $rv");
			}
		}
		alarm(0);
	};
	if($@ or !$rv) {
		close $rrdcached;
		$rrdcached = 0; # force reconnect next time
		do_log(1,"Read failed from rrdcached ($cmd)");
		return "-1 read failed";
	}

	# return status
	return $rv;
}
# update using rrdcached
sub update_rrdcached {
	my($rrdfile,$in,$out,$t,$max,$type) = @_;
	my($rv);

	return 0 if(! $config{mrtg}{enable} );
	if( $config{global}{test} ) {
		do_log(3,"NOT updating MRTG for $rrdfile [$t:$in:$out]");
		return 0;
	}
	$rv = send_mrtg("UPDATE $rrdfile $t:$in:$out");
	if($rv =~ /^-1 .*No such file/i and $config{mrtg}{create}) {
		my($maxin,$maxout);
		my($drows,$wrows,$mrows,$yrows);
		my($cmd);
		my($step,$heartbeat);
		$step = 300; # 5min
		$heartbeat = 2 * $config{'global'}{'frequency'};
		$heartbeat = 2*$step if(!$heartbeat);
		$yrows = 800;
		$yrows = $config{mrtg}{rows} if($config{mrtg}{rows});
		$drows = $wrows = $mrows = $yrows;
		$yrows = $config{mrtg}{yearly_rows}  if($config{mrtg}{yearly_rows});
		$mrows = $config{mrtg}{monthly_rows} if($config{mrtg}{monthly_rows});
		$wrows = $config{mrtg}{weekly_rows}  if($config{mrtg}{weekly_rows});
		$drows = $config{mrtg}{daily_rows}   if($config{mrtg}{daily_rows});
		$maxin = $maxout = 10240000000000; # 10TB
		$maxin = $maxout = 100 if($rrdfile =~ /_(cpu|pc)\.rrd/);
		$maxin = $maxout = $max if($max); # if we were passed an arg
		$type = "GAUGE" if(!$type or $type!~'COUNTER|GAUGE');
		
		do_log(2,"Creating RRD file $rrdfile, type $type, max $maxin");
		$cmd = "CREATE $rrdfile -s $step DS:ds0:$type:$heartbeat:0:$maxin DS:ds1:$type:$heartbeat:0:$maxout RRA:AVERAGE:0.5:1:$drows RRA:AVERAGE:0.25:6:$wrows RRA:AVERAGE:0.25:24:$mrows RRA:AVERAGE:0.25:288:$yrows RRA:MAX:0.5:1:$drows RRA:MAX:0.25:6:$wrows RRA:MAX:0.25:24:$mrows RRA:MAX:0.25:288:$yrows";
		do_log(3,"rrdtool $cmd");
		$rv = send_mrtg($cmd);
		if($rv =~ /^-1/) {
			do_log(0,"RRDcreate $rrdfile failed: $rv");
		} else {
			$rv = send_mrtg("UPDATE $rrdfile $t:$in:$out");
		}
	}
	if($rv =~ /^-1 .*illegal attempt to update/i ) {
		do_log(1,"RRDupdate $rrdfile seems to be a duplicate.");
		return 1;
	} elsif($rv =~ /^-1/ ) {
		do_log(0,"RRDupdate $rrdfile failed: $rv");
		return 2;
	} else {
		do_log(3,"RRDupdate $rrdfile $t:$in:$out success");
	}
	return 0;
}
# Update using RRDs
sub update_mrtg {
	my($rrdfile,$in,$out,$t,$max) = @_;
	return if(! $config{mrtg}{enable} );
	if( $config{mrtg}{persistent} ) {
		update_rrdcached(@_);
		return;
	}
	do_log(3,"Updating MRTG file $rrdfile");
	RRDs::update($rrdfile,"$t:$in:$out","--daemon",$config{mrtg}{rrdcached});
	if($RRDs::error) {
		do_log(1,"MRTG update of $rrdfile failed: ".$RRDs::error);
	}
}
sub check_datastores_mrtg($$$$) {
	my($item,$name,$t,$ctype)=@_;
	my($rrd,$in,$out,$free,$total);
	my($moref,$ds);
	my($maxbytes) = 1000000000000000; # 1EB, should be big enough...

	do_log(3, "check_datastores_mrtg Checking DS for $ctype ".$item->name);
	$free = $total = 0;
	if( $item->datastore ) {
	  foreach $moref ( @{$item->datastore} ) {
		do_log(4, "check_datastores_mrtg Retrieving DS ".$moref->{value});
		$ds = getview($moref);
		next if(!$ds);
		next if(!$ds->summary);
		do_log(4, "check_datastores_mrtg - Checking DS ".$ds->name);
		next if( $config{$ctype}{ds_include} and $ds->name!~/$config{$ctype}{ds_include}/i );
		next if( $config{$ctype}{ds_exclude} and $ds->name=~/$config{$ctype}{ds_exclude}/i );
		do_log(4, "check_datastores_mrtg -- Using DS ".$ds->name);
		if( $config{$ctype}{datastores} ) {
			# in detail
			$rrd = $name.'-'.$rrdfiles{$ctype}{datastore}.'-'.cleanup($ds->name).'.rrd';
			do_log(4, "check_datastores_mrtg Updating MRTG for $ctype on DS ".$ds->name." ($rrd)");
			$in = $ds->summary->capacity - $ds->summary->freeSpace; # used space
			$out = 'U';
			update_rrdcached($rrd,$in,$out,$t,$ds->summary->capacity);
		} 
		# summary
		$free  += $ds->summary->freeSpace; # freebytes
		$total += $ds->summary->capacity; # total bytes
	  }
	}
	# We always do the summary
	$in  = $total - $free; # change to used bytes
	$out = $total;
	$rrd = $name.'-'.$rrdfiles{$ctype}{datastores}.'.rrd';
	do_log(3, "check_datastores_mrtg Updating MRTG for $ctype on DS summary ($rrd;$in;$out)");
	$maxbytes = $total if($total>$maxbytes);
	update_rrdcached($rrd,$in,$out,$t,$maxbytes);
}
sub total_cpu_mem($) {
	my($cluster) = $_[0];
	my($totcpu,$totmem) = (0,0);
	my($availcpu,$availmem) = (0,0);
	my($cpupc,$mempc) = (-1,-1);
	my($view,$moref);

    eval {
		$availcpu = $cluster->summary->effectiveCpu;    # MHz
		$availmem = $cluster->summary->effectiveMemory; # MB
	};
    if($@) {
		do_log(0, "ERROR: $@" );
 		return(-2,-2,"ERROR: $@");
	}

	if($cluster->host) {
 	  foreach $moref (@{$cluster->host}) {
		$view = getview($moref);
		next if(!$view);
		next if(!$view->summary);
		$totcpu += $view->summary->quickStats->overallCpuUsage; # MHz
		$totmem += $view->summary->quickStats->overallMemoryUsage; # MB

	  }
	} else {
		return (-1,-1,"No active hosts in cluster");
	}

	$cpupc = $totcpu / $availcpu * 100 if($availcpu);
	$mempc = $totmem / $availmem * 100 if($availmem);
	return ($cpupc,$mempc,'');
}
# Loop through all the possible items we can update
sub do_update_mrtg() {
	my($item,$ds,$moref);
	my($name,$rrd,$in,$out,$t,$free,$total,$val);
	$t = $start;
	return if(! $config{mrtg}{enable} );
	do_log(2,"Processing MRTG updates");
	if( $config{'global'}{'datacenters'} and $datacenters ) {
		do_log(3,"Processing MRTG for datacenters");
		foreach $item ( @$datacenters ) {
			$name = 'dc_'.cleanup($item->name());
			do_log(3,"Processing MRTG for [$name]");
			# Update VM count
			$rrd = $name.'-'.$rrdfiles{datacenters}{active}.'.rrd';
			($out,$in) = count_vms($item);
			update_rrdcached($rrd,$in,$out,$t);
			# Update datastore usages
			check_datastores_mrtg($item,$name,$t,'datacenters');
			# Update network usages
			if($item->network) {
				foreach $moref ( @{$item->network} ) {
					# XXX To be done
				}
			}
		}
	}
	if( $config{'global'}{'clusters'} and $clusters  ) {
		do_log(3,"Processing MRTG for clusters");
		foreach $item ( @$clusters ) {
			$name = 'ccr_'.cleanup($item->name());
			do_log(3,"Processing MRTG for [$name]");
			# active VM count
			$rrd = $name.'-'.$rrdfiles{clusters}{active}.'.rrd';
			($out,$in) = count_vms($item);
			update_rrdcached($rrd,$in,$out,$t);
			# Update datastore usages
			check_datastores_mrtg($item,$name,$t,'clusters');
			# cpu/memory fairness
			$rrd = $name.'-'.$rrdfiles{clusters}{fairness}.'.rrd';
			($in,$out) = ($item->summary->currentBalance, $item->summary->targetBalance);
			update_rrdcached($rrd,$in,$out,$t,100000);
			# CPU/memory usage
			# need to total up the component hosts
			$rrd = $name.'-'.$rrdfiles{clusters}{resources}.'.rrd';
			($in,$out) = total_cpu_mem($item);
			update_rrdcached($rrd,$in,$out,$t,100);
		}
	}
	if( $config{'global'}{'hosts'} and $hosts  ) {
		foreach $item ( @$hosts ) {
			my($cpupc,$mempc)=(-1,-1);
			my($fn,$na) = identify($item,0);
			next if(!$fn);
			do_log(3,"Processing MRTG for [$na]");
			# Update datastore usages
			# check_datastores_mrtg($item,$fn,$t,'hosts');
			# host stats 
			# active VM count?
			$rrd = $fn.'-'.$rrdfiles{hosts}{active}.'.rrd';
			($out,$in) = count_vms($item);
			update_rrdcached($rrd,$in,$out,$t,100000);
			# cpu/memory fairness XXXX
			# CPU/memory usage 
			$rrd = $fn.'-'.$rrdfiles{hosts}{resources}.'.rrd';
			$cpupc = $item->summary->quickStats->overallCpuUsage * 100.0 / ( $item->summary->hardware->cpuMhz * $item->summary->hardware->numCpuCores )
				if($item->summary->hardware->cpuMhz);
			$mempc = $item->summary->quickStats->overallMemoryUsage * 1024000 * 100.0 / $item->summary->hardware->memorySize
				if($item->summary->hardware->memorySize);
			update_rrdcached($rrd,$cpupc,$mempc,$t,100);

			$rrd = $fn.'-'.$rrdfiles{hosts}{disk}.'.rrd';
			update_rrdcached($rrd,$item->{'disk:usage'}*1024,0,$t);
			if( $config{'hosts'}{'datastores'} ) {
				# detailed disk throughput? XXXX
			}

			$rrd = $fn.'-'.$rrdfiles{hosts}{net}.'.rrd';
			update_rrdcached($rrd,$item->{'net:usage'}*1024,0,$t);
			if( $config{'hosts'}{'network'} ) {
				# detailed network throughput? XXXX
			}

			$rrd = $fn.'-'.$rrdfiles{hosts}{swap}.'.rrd';
			update_rrdcached($rrd,$item->{'mem:swapinRate'}*1024,$item->{'mem:swapoutRate'}*1024,$t);
		}
	}
	if( $config{'global'}{'guests'} and $guests ) {
		foreach $item ( @$guests ) {
			my($qs,$cpumax,$memmax,$cpupc,$mempc);
			my($fn,$na) = identify($item,$config{nagios}{verify});
			next if(!$fn);
			my $qs = $item->summary->quickStats;
			do_log(3,"Processing MRTG for [$na]");
			# Guest stats 
			$qs = $item->summary->quickStats;
			next if(!$qs or !$item->summary->runtime);
			# cpu/memory usage 
			$rrd = $fn.'-'.$rrdfiles{guests}{resources}.'.rrd';
			$cpumax = $item->summary->runtime->maxCpuUsage;
			if( $cpumax ) {
				$cpupc = int(100 * $qs->overallCpuUsage / $cpumax * 100.0)/100;
			} else {
				$cpupc = 'U';
			}
			$memmax = $item->summary->runtime->maxMemoryUsage;
			if( $memmax ) {
				$mempc = int(100*$qs->guestMemoryUsage/$memmax*100)/100;
			} else {
				$mempc = 'U';
			}
			next if( update_rrdcached($rrd,$cpupc,$mempc,$t,100) );
			# This will catch duplicates

			# Memory active
			$rrd = $fn.'-'.$rrdfiles{guests}{memory}.'.rrd';
			if( $memmax ) {
				update_rrdcached($rrd,
					($qs->guestMemoryUsage*100.0/$memmax),0,$t);
			} else {
				update_rrdcached($rrd,-1,-1,$t);
			}

			# cpu detail
			# usr/rdy wait/inter
			$rrd = $fn.'-'.$rrdfiles{guests}{cpu1}.'.rrd';
			update_rrdcached($rrd,$item->{'cpu:used'},$item->{'cpu:ready'},$t,100);
			$rrd = $fn.'-'.$rrdfiles{guests}{cpu2}.'.rrd';
			update_rrdcached($rrd,$item->{'cpu:system'},$item->{'cpu:wait'},$t,100);

			if( $config{'guests'}{'memory'} ) {
				# memory detail
				# pvt/shared, balloon/swap
				$rrd = $fn.'-'.$rrdfiles{guests}{mem1}.'.rrd';
				if($memmax) {
					update_rrdcached($rrd,
						($qs->privateMemory/$memmax*100.0),
						($qs->sharedMemory/$memmax*100.0),
						$t,100);
				} else {
					update_rrdcached($rrd,-1,-1,$t,100);
				}
				$rrd = $fn.'-'.$rrdfiles{guests}{mem2}.'.rrd';
				if($memmax) {
					update_rrdcached($rrd,
						($qs->balloonedMemory/$memmax*100.0),
						($qs->swappedMemory/$memmax*100.0),
						$t,100);
				} else {
					update_rrdcached($rrd,-1,-1,$t,100);
				}
			}
			$rrd = $fn.'-'.$rrdfiles{guests}{disk}.'.rrd';
			update_rrdcached($rrd,
				($item->{'disk:usage'}*1024.0),
				($item->{'disk:usage'}*1024.0),
				$t);
			if( $config{'guests'}{'datastores'} ) {
				# disk throughput? XXXX
				foreach my $k ( @{$item->{devices_hd}} ) {
					$rrd = $fn.'-'.$rrdfiles{guests}{disk}."-$k.rrd";
					update_rrdcached($rrd,
						($item->{"virtualDisk:write:$k"}*1024.0),
						($item->{"virtualDisk:read:$k"}*1024.0),
						$t);
					$rrd = $fn.'-'.$rrdfiles{guests}{latency}."-$k.rrd";
					update_rrdcached($rrd,
						($item->{"virtualDisk:totalReadLatency:$k"}/1000),
						($item->{"virtualDisk:totalWriteLatency:$k"}/1000),
						$t);
				}
			}
			$rrd = $fn.'-'.$rrdfiles{guests}{network}.'.rrd';
			update_rrdcached($rrd,
				($item->{'net:usage'}*1024.0),
				($item->{'net:usage'}*1024.0),
				$t);
			if( $config{'guests'}{'network'} ) {
				# network throughput? XXXX
				foreach my $k ( @{$item->{devices_net}} ) {
					$rrd = $fn.'-'.$rrdfiles{guests}{network}."-$k.rrd";
					update_rrdcached($rrd,
						($item->{"net:received:$k"}*1024.0),
						($item->{"net:transmitted:$k"}*1024.0),
						$t);
				}
			}
		}
	}
}
sub check_alarms($) {
	my($item) = $_[0];
	my($status,$msg);
	my($s,$alrm,$aentity,$adef);
	$status = 0; $msg = "";
	if($item->triggeredAlarmState) {
		foreach $alrm ( @{$item->triggeredAlarmState} ) {
			$s = $alrm->overallStatus->val;
			next unless($s eq 'red' or $s eq 'yellow');
			$aentity = getview($alrm->entity);
			$adef = getview($alrm->alarm);
			next unless($aentity and $adef and $adef->info);
			$status = 2 if($s eq 'red');
			$status = 1 if(!$status and $s eq 'yellow');
			$msg .= "\\n" if($msg);
			$msg .= "[".$aentity->name."] ".$adef->info->name." is $s";
		}
	}
	if(!$msg) {
		$msg = "All alarms OK";
	} elsif( $msg =~ /\\n/ ) {
		$msg = "Multiple alarms detected:\\n$msg";
	}
	return ($status,$msg);
}
sub check_datastores($$$) {
	my($item,$name,$ctype) = @_;
	my($free,$total,$status,$pc,$ds,$moref);

	$free = $total = 0;
	if( $item->datastore ) {
	  foreach $moref ( @{$item->datastore} ) {
		$ds = getview($moref);
		next if(!$ds or !$ds->name);
		next if( $config{$ctype}{ds_include} and $ds->name!~/$config{$ctype}{ds_include}/i );
		next if( $config{$ctype}{ds_exclude} and $ds->name=~/$config{$ctype}{ds_exclude}/i );
		if( $config{$ctype}{datastores} ) {
			# in detail
			$status = 0;
			if($ds->summary->capacity) {
				$pc = ($ds->summary->capacity - $ds->summary->freeSpace)*100/$ds->summary->capacity;
				$status = 1 if($ds->summary->freeSpace<threshold('dsk','warn',[$name,$ctype]));
				$status = 2 if($ds->summary->freeSpace<threshold('dsk','crit',[$name,$ctype]));
				send_nagios_status($name,$servicedesc{$ctype}{datastore}.": ".$ds->name,$status,
					"Datastore usage at ".(int($pc*10)/10)."\% of "
						.int($ds->summary->capacity/1024000000)."GB.  ".int($ds->summary->freeSpace/1024000000)."GB free|"
						." usedpc=$pc\%;;;0;100"
						." free=".$ds->summary->freeSpace.";"
						.threshold('dsk','warn',[$name,$ctype]).";"
						.threshold('dsk','crit',[$name,$ctype]).";0;"
						.$ds->summary->capacity
						." used=".($ds->summary->capacity - $ds->summary->freeSpace).";;;0;".$ds->summary->capacity
				);
			} else {
				send_nagios_status($name,$servicedesc{$ctype}{datastore}.": ".$ds->name,3,
					"Unable to identify datastore usage for ".$ds->name);
			}
		} 
		# summary
		$free  += $ds->summary->freeSpace; # freebytes
		$total += $ds->summary->capacity; # total bytes
	  }
	}
	if( ! $config{$ctype}{datastores} ) {
		$status = 0;
		if($total) {
			$pc = ($total - $free)*100/$total;
			$status = 1 if($free<threshold('dsk','warn',[$name,$ctype]));
			$status = 2 if($free<threshold('dsk','crit',[$name,$ctype]));
			send_nagios_status($name,$servicedesc{$ctype}{datastores},$status,
				"Overall datastore usage at ".(int($pc*10)/10)."\% of "
					.int($total/1024000000)."GB.  ".int($free/1024000000)."GB free|"
					."usedpc=$pc\%;;;0;100 free=$free;"
					.threshold('dsk','warn',[$name,$ctype]).";"
					.threshold('dsk','crit',[$name,$ctype]).";0;$total used="
					.($total-$free).";;;0;$total"
			);
		} else {
			send_nagios_status($name,$servicedesc{$ctype}{datastores},3,
				"Unable to identify datastore usage: are any datastores defined?");
		}
	}
}
# Loop through all the possible items we can update
sub do_update_nagios() {
	my($item,$ds,$moref,$total,$free,$pc,$fname,$name,$status,$msg,$val);
	my($s,$aentity,$adef,$cpu,$mem,$qs,$rv);
	return if(! $config{nagios}{enable} );
	do_log(2,"Processing Nagios updates");

	if( $config{'global'}{'datacenters'} and $datacenters ) {
		foreach $item ( @$datacenters ) {
			$name = 'dc_'.cleanup($item->name());
			do_log(3,"Running Nagios update for $name");
			send_nagios_status($name,'',0,'See individual services for status');
			# check vc alarms
			($status,$msg) = check_alarms($item);
			send_nagios_status($name,$servicedesc{datacenters}{alarms},$status,$msg);
			# check datastore usage
			check_datastores($item,$name,'datacenters');
			# check interface usage
			if( $config{datacenters}{network} and $item->network ) {
				foreach $moref ( @{$item->network} ) {
					# To be done XXX
				}
			}
		}
	}
	if( $config{'global'}{'clusters'} and $clusters ) {
		foreach $item ( @$clusters ) {
			$name = 'ccr_'.cleanup($item->name());
			do_log(3,"Running Nagios update for $name");
			send_nagios_status($name,'',0,'See individual services for status');
			$status = $item->overallStatus->val;
			send_nagios_status($name,$servicedesc{clusters}{status},$mapstatus{$status},"Cluster status is <A href=https://$config{vmware}{server}:9443/vsphere-client/>$status</A>");
			# check vc alarms
			($status,$msg) = check_alarms($item);
			send_nagios_status($name,$servicedesc{clusters}{alarms},$status,$msg);
			# check datastore usage
			check_datastores($item,$name,'clusters');
			# check cluster fairness
			$val = (int($item->summary->currentBalance * 10000 / $item->summary->targetBalance)/100)-100;
			$msg = "Current cluster resource balance "
				.(($val>0)?"+":"")
				."$val\% (current=".$item->summary->currentBalance.", target=".$item->summary->targetBalance.")";
			$status = 0; 
			$status = 1 if(abs($val)>threshold('balance','warn',[$name,'clusters']));
			$status = 2 if(abs($val)>threshold('balance','crit',[$name,'clusters']));
			if($item->summary->currentBalance == 0) {
				$status = 3;
				$msg = "Unable to determine cluster balance (is DDR enabled?)";
			}
			send_nagios_status($name,$servicedesc{clusters}{fairness},$status,$msg);
			# check CPU usage
			# Need to total up from member hosts, convert to %
			($cpu,$mem,$rv) = total_cpu_mem($item); # percentages
			if($cpu<0) {
				$status = 3;
				$msg = "Cannot determine cluster CPU usage.\\n$rv|err=$cpu;;;;";
			} else {
				$cpu = int(100*$cpu)/100;
				$status = 0;
				$status = 1 if($cpu>=threshold('cpu','warn',[$name,'clusters']));
				$status = 2 if($cpu>=threshold('cpu','crit',[$name,'clusters' ]));
				$msg="Cluster CPU usage $cpu\%|cpu=$cpu\%;"
					.threshold('cpu','warn',[$name,'clusters']).";"
					.threshold('cpu','crit',[$name,'clusters']).";0;100";
			}
			send_nagios_status($name,$servicedesc{clusters}{cpu},$status,$msg);
			if($mem<0) {
				$status = 3;
				$msg = "Cannot determine cluster Memory usage.\\n$rv|err=$mem;;;;";
			} else {
				$mem = int(100*$mem)/100;
				$status = 0;
				$status = 1 if($mem>=threshold('mem','warn',[$name,'clusters']));
				$status = 2 if($mem>=threshold('mem','crit',[$name,'clusters']));
				$msg="Cluster Memory usage $mem\%|memory=$mem\%;"
					.threshold('mem','warn',[$name,'clusters']).";"
					.threshold('mem','crit',[$name,'clusters']).";0;100";
			}
			send_nagios_status($name,$servicedesc{clusters}{memory},$status,$msg);
		}
	}
	if( $config{'global'}{'hosts'} and $hosts ) {
		foreach $item ( @$hosts ) {
			($fname,$name) = identify($item,0);
			next if(!$name);
			do_log(3,"Running Nagios update for $name");
			# host check is active.
#			$status = $item->runtime->powerState->val;
#			send_nagios_status($name,'',$mapstatus{$status},"Host status is $status");
			$status = $item->overallStatus->val;
			send_nagios_status($name,$servicedesc{hosts}{status},$mapstatus{$status},"ESX Host status is <A href=https://$config{vmware}{server}:9443/vsphere-client/>$status</A>");
			# check vc alarms
			($status,$msg) = check_alarms($item);
			send_nagios_status($name,$servicedesc{hosts}{alarms},$status,$msg);
			# info page
			my($ccr) = find_cluster($item->parent());
			$msg = "ESX Host: ".$item->name.", Cluster: "
				.($ccr?(
					"<A href=\"".$config{nagios}{'link'}."ccr_".cleanup($ccr->name)."\">"
					.cleanup($ccr->name)."</A>"
				):"none");
			send_nagios_status($name,$servicedesc{hosts}{info},0,$msg);
			# check datastore usage XXX
			# check_datastores($item,$name,'hosts');A

			# check CPU usage
			# Should I be using numCpuThreads here instead of numCpuCores?
			$cpu = $item->summary->quickStats->overallCpuUsage * 100.0 / ( $item->summary->hardware->cpuMhz * $item->summary->hardware->numCpuCores );
			$cpu = int(100*$cpu)/100;
			$status = 0;
			$status = 1 if($cpu>=threshold('cpu','warn',[$name,'hosts']));
			$status = 2 if($cpu>=threshold('cpu','crit',[$name,'hosts']));
			$msg="Host CPU usage $cpu\%|cpu=$cpu\%;"
				.threshold('cpu','warn',[$name,'hosts']).";"
				.threshold('cpu','crit',[$name,'hosts']).";0;100";
			$msg .= " usage=".($item->summary->quickStats->overallCpuUsage*1000000)."hz;;;0; ";
			send_nagios_status($name,$servicedesc{hosts}{cpu},$status,$msg);
			# check memory usage
			$mem = $item->summary->quickStats->overallMemoryUsage * 1024000 * 100.0 / $item->summary->hardware->memorySize;
			$mem = int(100*$mem)/100;
			$status = 0;
			$status = 1 if($mem>=threshold('mem','warn',[$name,'hosts']));
			$status = 2 if($mem>=threshold('mem','crit',[$name,'hosts']));
			$msg="Host Memory usage $mem\%";
			$msg .= "\\nSwap activity: i/o ".$item->{'mem:swapinRate'}
				." / ".$item->{'mem:swapoutRate'}." Kps";
			$status = 2 if($item->{'mem:swapinRate'}>threshold('swp','crit',[$name,'hosts']));
			$status = 1 if(!$status and $item->{'mem:swapinRate'}>threshold('swp','warn',[$name,'hosts']));
			$msg .= "|memory=$mem\%;"
				.threshold('mem','warn',[$name,'hosts']).";"
				.threshold('mem','crit',[$name,'hosts']).";0;100 ";
			$msg .= "swapIn=".($item->{'mem:swapinRate'}*1024).";"
				.threshold('swp','warn',[$name,'hosts']).";"
				.threshold('swp','crit',[$name,'hosts']).";0; ";
			$msg .= "swapOut=".($item->{'mem:swapoutRate'}*1024).";;;0; ";

			send_nagios_status($name,$servicedesc{hosts}{memory},$status,$msg);

			if( $config{nagios}{ntp} and $config{nagios}{ntp} ne 'never' ) {
				$config{nagios}{thresh_ntp_warn}=1 if(!$config{nagios}{thresh_ntp_warn});
				if(! defined $ntp{$name} ) {
					$msg = "Time cannot be retrieved (check ESX host firewall rules)";
					$status = 3;
				} elsif(( $ntp{$name} > threshold('ntp','crit',[$name,'hosts']) )
					or( $ntp{$name} < -threshold('ntp','crit',[$name,'hosts']) )) {
					$msg = "Time not synchronised! (Offset: ".$ntp{$name}."s, threshold ".threshold('ntp','crit',[$name,'hosts'])."s)";
					$status = 2;
				} elsif(( $ntp{$name} > threshold('ntp','warn',[$name,'hosts']) )
					or( $ntp{$name} < -threshold('ntp','warn',[$name,'hosts']) )) {
					$msg = "Time not synchronised! (Offset: ".$ntp{$name}."s, threshold ".threshold('ntp','warn',[$name,'hosts']) ."s)";
					$status = 1;
				} else {
					$msg = "Time synchronised OK (Offset: ".$ntp{$name}."s)";
					$status = 0;
				}
				send_nagios_status($name,$servicedesc{hosts}{time},$status,$msg);
			}

			# disk activity
			$status = 0;
			$msg = "Total disk IO ".($item->{'disk:usage'}/1024)." MB/s";
			$msg .= "|disk=".($item->{'disk:usage'}*1024).";;;0; ";
			send_nagios_status($name,$servicedesc{hosts}{disk},$status,$msg);

			# net activity
			$status = 0;
			$msg = "Total network IO ".($item->{'net:usage'}/1024)." MB/s";
			$msg .= "|net=".($item->{'net:usage'}*1024).";;;0; ";
			send_nagios_status($name,$servicedesc{hosts}{net},$status,$msg);
		}
	}
	if( $config{'global'}{'guests'} and $guests  ) {
		foreach $item ( @$guests ) {
			my($max)=0;	
			my($perf);
			($fname,$name) = identify($item,$config{'nagios'}{'verify'});
			next if(!$name);
			$qs = $item->summary->quickStats;
			do_log(3,"Running Nagios update for $name");
			$status = $item->runtime->powerState->val;
			if( $status eq 'poweredOff' or $item->guest->guestState eq 'notRunning' ) {
				send_nagios_status($name,'',1,"VM $status; Guest ".$item->guest->guestState);
				foreach ( qw/alarms status cpu memory net disk/ ) {
					send_nagios_status($name,$servicedesc{guests}{$_},3,"Guest is not running");
				}
				next;
			} else {
				send_nagios_status($name,'',0,"VM $status; Guest ".$item->guest->guestState);
				# host check is active.
			}
			# check vc alarms
			($status,$msg) = check_alarms($item);
			send_nagios_status($name,$servicedesc{guests}{alarms},$status,$msg);
			$status = $item->overallStatus->val;
			send_nagios_status($name,$servicedesc{guests}{status},$mapstatus{$status},"Virtual machine status is <A href=https://$config{vmware}{server}:9443/vsphere-client/>$status<A>");

			# info page
			my($ccr) = find_cluster($item->resourcePool);
			my($host) = $item->runtime->host;
			my($hostview) = ($host?getview($host):"");
			my($a,$b)  = identify($hostview,0);
			$msg = "Guest name: ".$item->name."\\nESX Host: "
				.($host?(
					"<A href=\"".$config{'nagios'}{'link'}.$b."\">"
					.($hostview->name)."</A>"
				):"none")
				."\\nCluster: "
				.($ccr?(
					"<A href=\"".$config{'nagios'}{'link'}."ccr_".cleanup($ccr->name)."\">"
					.cleanup($ccr->name)."</A>"
				):"none");
			send_nagios_status($name,$servicedesc{guests}{info},0,$msg);

			# check CPU usage
			$status = 0;	
			$max = $item->summary->runtime->maxCpuUsage;
			if( $max ) {
				$pc = int(100 * $qs->overallCpuUsage / $max * 100.0)/100;
				$msg = "Spot CPU usage $pc\% of maximum ("
					.$qs->overallCpuUsage."MHz from ${max}MHz)"
					."\\n5min avg CPU% used/ready/sys = "
					.(int($item->{'cpu:used'}*100)/100)."\%/"
					.(int($item->{'cpu:ready'}*100)/100)."\%/"
					.(int($item->{'cpu:system'}*100)/100)."\%";

				if($pc >= threshold('cpu','warn',[$name,'guests']) ) {
					$msg .= "\\nCPU usage is too high - check running processes!";
					$status = 1 ;
					$status = 2 if($pc >= threshold('cpu','crit',[$name,'guests']) );
				}

				# add a ready time check here
				if ($item->{'cpu:ready'} >= threshold('rdy','warn',[$name,'guests']) ) {
					$msg .= "\\nReady time is too high - check ESX resource pools!";
					$status = 1 if( $status < 1 );
					$status = 2 if( $item->{'cpu:ready'} >= threshold('rdy','crit',[$name,'guests'])  );
				}

				$msg .=	"|cpu=$pc\%;". threshold('cpu','warn',[$name,'guests'])
					.";". threshold('cpu','crit',[$name,'guests']).";0;100 "
					."usage=".($qs->overallCpuUsage*1000000)."hz;;"
					.($max*10000*threshold('cpu','crit',[$name,'guests']))
					.";0;".($max*1000000)." "
					."used=".$item->{'cpu:used'}."\%;;;0;100 "
					."ready=".$item->{'cpu:ready'}."\%;"
						.threshold('rdy','warn',[$name,'guests']).";"
						.threshold('rdy','crit',[$name,'guests']).";0;100 "
					."system=".$item->{'cpu:system'}."\%;;;0;100 "
					."wait=".$item->{'cpu:wait'}."\%;;;0;100 ";
			} else {
				$status = 3;
				$msg = "Unable to obtain CPU usage";
			}
			send_nagios_status($name,$servicedesc{guests}{cpu},$status,$msg);
			# check memory usage
			$max = $item->summary->runtime->maxMemoryUsage;
			if( $max ) {
				$status = 0; 
				$msg = "Memory total ${max}MB";
				$msg .= "\\nPrivate memory: ".$qs->privateMemory." MB ("
					.int($qs->privateMemory/$max*100)."%)";
				$msg .= "\\nShared memory : ".$qs->sharedMemory." MB ("
					.int($qs->sharedMemory/$max*100)."%)";
				$msg .= "\\nBalloon memory: ".$qs->balloonedMemory." MB ("
					.int($qs->balloonedMemory/$max*100)."%)";
				$msg .= "\\nSwapped memory: ".$qs->swappedMemory." MB ("
					.int($qs->swappedMemory/$max*100)."%)";
				$pc = int(100*$qs->guestMemoryUsage/$max*100)/100;
				$msg .= "\\nActive memory: $pc\%";
				$status = 1 if($pc >= threshold('mem','warn',[$name,'guests']));
				$status = 2 if($pc >= threshold('mem','crit',[$name,'guests']));
				if(defined $item->{'mem:swapinRate'}) {
					$msg .= "\\nESX swapin rate: ".$item->{'mem:swapinRate'}." KB/s";
				}
				$pc = $qs->swappedMemory/$max*100;
				if( $pc>=threshold('swp','warn',[$name,'guests']) ) { 
					$status = 1 unless($status); 
					$status = 2 if( $pc>=threshold('swp','crit',[$name,'guests']));
					$msg .= "\\nSome memory is swapped out on ESX Server!";
				}
				$pc = $qs->balloonedMemory/$max*100;
				if( $pc>=threshold('bal','warn',[$name,'guests']) ) { 
					$status = 2 if( $pc>=threshold('bal','crit',[$name,'guests']));
					$status = 1 unless($status); 
					$msg .= "\\nSome memory is being reclaimed by the balloon driver!";
				}
				if(defined $item->{'mem:swapinRate'}) {
				  if($item->{'mem:swapinRate'}>=threshold('swapin','warn',[$name,'guests'])) {
					$status = 2 if($item->{'mem:swapinRate'}>=threshold('swapin','crit',[$name,'guests']));
					$status=1 unless($status);
					$msg .= "\\nExcessive swapping at ESX server level!";
				  }
				} else {
					$msg .= "\\nSwap activity statistics not available!";
				}
				$msg .= "|"
					."memory=".($qs->hostMemoryUsage*1024000).";;;0;" .($max*1024000)." "
					."active=".($qs->guestMemoryUsage*1024000).";"
						.";" .(threshold('mem','crit',[$name,'guests'])*$max*10240)
						.";0;" .($max*1024000)." "
					."balloon=".($qs->balloonedMemory*1024000).";;"
						.(threshold('bal','crit',[$name,'guests'])*$max*10240)
						.";0;" .($max*1024000)." "
					."private=".($qs->privateMemory*1024000).";;;0;" .($max*1024000)." "
					."shared=".($qs->sharedMemory*1024000).";;;0;" .($max*1024000)." "
					."swapped=".($qs->swappedMemory*1024000).";;"
						.(threshold('swp','crit',[$name,'guests'])*$max*10240)
						.";0;" .($max*1024000)." ";
#				if(defined $item->{'mem:swapinRate'}) {
				  $msg .=
					"swapIn=".($item->{'mem:swapinRate'}*1024).";"
						.(threshold('swapin','warn',[$name,'guests'])*1024).";"
						.(threshold('swapin','crit',[$name,'guests'])*1024).";0; "
					."swapOut=".($item->{'mem:swapoutRate'}*1024).";;;0; " ;
#				}
			} else {
				$status = 3;
				$msg = "Unable to obtain Memory usage";
			}
			send_nagios_status($name,$servicedesc{guests}{memory},$status,$msg);

			# disk throughput?
			if(defined $item->{'disk:usage'}) {
			$status = 0; $msg = ""; $perf="";
			$msg = "Overall virtual disk usage: ".$item->{'disk:usage'}." KB/s";
			$perf = "usage=".($item->{'disk:usage'}*1024).";;;0; ";
			foreach my $k ( @{$item->{devices_hd}} ) {
				my $nam = devdesc($item,$k);
				my $rlval = $item->{"virtualDisk:totalReadLatency:$k"};
				my $wlval = $item->{"virtualDisk:totalWriteLatency:$k"};
				my $rval = $item->{"virtualDisk:read:$k"};
				my $wval = $item->{"virtualDisk:write:$k"};
				$msg .= "\\n- $nam\\n-- r/w = $rval / $wval KB/s";
				$msg .= "\\n-- latency = $rlval / $wlval ms";
				if( $rlval >= threshold('latency','warn',[$name,'guests'])
					or $wlval >= threshold('latency','warn',[$name,'guests']) ) {	
					$status = 1 if(!$status);
					$status = 2 if( $rlval >= threshold('latency','crit',[$name,'guests']) or $wlval >= threshold('latency','crit',[$name,'guests']) );
					$msg .= "\\n--- Over threshold!";
				}
				$perf .= devdesc($item,$k)."-r=".($rval*1024).";;;0; ";
				$perf .= devdesc($item,$k)."-w=".($wval*1024).";;;0; ";
				$perf .= devdesc($item,$k)."-latency-r=".($rlval/1000).";"
					.threshold('latency','warn',[$name,'guests']).";"
					.threshold('latency','crit',[$name,'guests']).";"
					.";0; ";
				$perf .= devdesc($item,$k)."-latency-w=".($wlval/1000).";"
					.threshold('latency','warn',[$name,'guests']).";"
					.threshold('latency','crit',[$name,'guests']).";"
					.";0; ";
			}
			$msg = "No disk issues." if(!$msg);
			} else {
				$status=3;
				$msg="No disk usage statistics available.";
			}
			send_nagios_status($name,$servicedesc{guests}{disk},$status,"$msg|$perf");

			# network usage by guest
			if(defined $item->{'net:usage'}) {
			$status = 0;  $perf="";
			$msg = "Overall network usage: ".$item->{'net:usage'}." KB/s";
			$perf = "usage=".($item->{'net:usage'}*1024).";;;0; ";
			foreach my $k ( @{$item->{devices_net}} ) {
				$msg .= "\\n- "
					.devdesc($item,$k)
					." : r/w = ".$item->{"net:received:$k"}
					." / ".$item->{"net:transmitted:$k"}
					." KB/s";
				$perf .= devdesc($item,$k)."-r=".($item->{"net:received:$k"}*1024).";;;0; "
					.devdesc($item,$k)."-w=".($item->{"net:transmitted:$k"}*1024).";;;0; ";
			}
			$msg = "No network issues." if(!$msg);
			} else {
				$status=3;
				$msg="No network usage statistics available.";
			}
			send_nagios_status($name,$servicedesc{guests}{net},$status,"$msg|$perf");

		}
	}
}
sub do_update() {
	do_log(3,"MRTG update enabled:".$config{mrtg}{enable});
	if( $config{mrtg}{enable} ) {
		do_update_mrtg();
	}
	do_log(3,"Nagios update enabled:".$config{nagios}{enable});
	if( $config{nagios}{enable} ) {
		do_update_nagios();
	}
}
#############################################################################
# config writing functions

sub make_path($) {
	my($path) = $_[0];
	my($p) = '';
	foreach my $c ( split /\//,$path ) {
		next if(!$c or $c eq '.');
		$p .= "/$c";
		next if(-d $p);
		mkdir $p;
		if( ! -d $p ) {
			do_log(0,"Cannot create directory $p\n$!");
			exit(2);
		}
	}
}
sub write_cfg_type($) {
	my($type) = $_[0];
	my($item,$file,$content,%vars,$template,$dc,$ccr,$hs,@h);
	my(@ds,$v);
	my(%done) = ();
	my($name);

	do_log(3,"Making $type config files");
	$cfghosts{$type} = ();
	if(!$tt) {
		do_log(0,"Template object not set!  This should never happen!");
		initialise_tt();
	}
	if( $config{'global'}{'datacenters'} and $config{$type}{"cfg_datacenter"} 
		and $config{$type}{"tt2_datacenter"} and $datacenters ) {
		make_path( $config{$type}{"cfg_datacenter"} );
		# now export datacentre cfg files
		%done = ();
		foreach $item ( @$datacenters ) {
			do_log(3,"Making $type config file for ".$item->name());
			$file = 'dc_'.cleanup($item->name()).".cfg"; # just to be unique
			$file =~ s/ /_/g;
			$file = $config{$type}{"cfg_datacenter"}."/$file";
			$template = $config{$type}{"tt2_datacenter"};
			@ds = ();
			if( $config{datacenters}{datastores} and $item->datastore ) {
				foreach ( @{$item->datastore} ) { 
					$v = getview($_); next if(!$v);
					next if( $config{datacenters}{ds_include} and $v->name!~/$config{datacenters}{ds_include}/i );
					next if( $config{datacenters}{ds_exclude} and $v->name=~/$config{datacenters}{ds_exclude}/i );
					push @ds, $v; 
				}
			}
#				open FOO,">/tmp/dump.vmware";
#				print FOO Dumper($item);
#				close FOO;
			$name = 'dc_'.cleanup($item->name());
			next if($cfghosts{$type}{$name});
			%vars = (
				'this' => $item,
				'name' => $name,
				'clusters' => [ ], # XXX find these out
				'interval' => $config{'global'}{'frequency'}, # not strictly necessary
				'interfaces' => [ ],
				'datastores' => \@ds,
				'moid' => $item->{mo_ref}->{value},
			);
			if(! $tt->process($template,\%vars,$file)){
				do_log(0,"Failed to process template $template\n".$tt->error());
			} else { $cfghosts{$type}{$name}= 1; 
				$done{$file}=1;
			}
		}
		if( $config{$type}{"purge"} ) {
			foreach $file ( glob($config{$type}{"cfg_datacenter"}."/*.cfg") ) {
				next if( -d $file );
				unlink $file if(!$done{$file});
			}
		}
	}
	if( $config{'global'}{'clusters'} and $config{$type}{"cfg_cluster"} 
		and $config{$type}{"tt2_cluster"} and $clusters ) {
		make_path( $config{$type}{"cfg_cluster"} );
		# now export cluster cfg files
		%done = ();
		do_log(3,"Creating cluster config files for $type");
		foreach $item ( @$clusters ) {
			do_log(3,"Making $type config file for ".$item->name());
			$file = 'ccr_'.cleanup($item->name()).".cfg"; # just to be unique
			$file = $config{$type}{"cfg_cluster"}."/$file";
			$template = $config{$type}{"tt2_cluster"};
			$dc = find_datacenter($item->parent());
			do_log(3,"Finding child hosts");
			@h = ();
			if($item->host) {
				foreach $hs ( @{$item->host} ) {
					my ($n,$fn,$na,$v);
					do_log(3,"Checking cluster host ".$hs->{value});
					$v = getview($hs); next if(!$v);
					do_log(4,"Given object type ".(ref $v));
					$n = $v->name();
					do_log(4,"Object name $n");
					($fn,$na) = identify($v,0);
					push @h, $na if($na);
				}
			}
			next if(!@h); # dont make a config if there are no hosts in this cluser!
			@ds = ();
			if( $config{clusters}{datastores} and $item->datastore ) {
				foreach ( @{$item->datastore} ) { 
					$v = getview($_); next if(!$v);
					next if( $config{clusters}{ds_include} and $v->name!~/$config{clusters}{ds_include}/i );
					next if( $config{clusters}{ds_exclude} and $v->name=~/$config{clusters}{ds_exclude}/i );
					push @ds, $v; 
				}
			}
			$name = 'ccr_'.cleanup($item->name());
			next if($cfghosts{$type}{$name});
			do_log(3,"Calling template toolkit");
			%vars = (
				'this' => $item,
				'name' => $name,
				'hosts' => \@h,
				'datacenter' => ($dc?('dc_'.cleanup($dc->name())):''),
				'interval' => $config{'global'}{'frequency'},
				'datastores' => \@ds, 
				'moid' => $item->{mo_ref}->{value},
			);
			if(! $tt->process($template,\%vars,$file)){
				do_log(0,"Failed to process template $template\n".$tt->error());
			} else {
				$cfghosts{$type}{$name}=1;
				$done{$file}=1;
			}
		}
		if( $config{$type}{"purge"} ) {
			foreach $file ( glob($config{$type}{"cfg_cluster"}."/*.cfg") ) {
				next if( -d $file );
				unlink $file if(!$done{$file});
			}
		}
	}
	if( $config{'global'}{'hosts'} and $config{$type}{"cfg_host"} 
		and $config{$type}{"tt2_host"} and $hosts ) {
		make_path( $config{$type}{"cfg_host"} );
		# now export server cfg files
		%done = ();
		do_log(3,"Creating host config files for $type");
		foreach $item ( @$hosts ) {
			my($fn,$na);
			my($cn) = cleanup($item->name());
			($fn,$na) = identify($item,0);
			next if(!$name);
			next if($cfghosts{$type}{$na});
			do_log(3,"Making $type config file for $cn");
			$file = "${cn}.cfg"; # just to be unique
			$file = $config{$type}{"cfg_host"}."/$file";
			$template = $config{$type}{"tt2_host"};
			$ccr = find_cluster($item->parent());
			$dc = find_datacenter($ccr); # in case ccr is null
			%vars = (
				'this' => $item,
				'name' => $na,
				'fqdn' => $fn,
				'cluster'    => ($ccr?('ccr_'.cleanup($ccr->name())):''),
				'datacenter' => ($dc?('dc_'.cleanup($dc->name())):''),
				'interval'   => $config{'global'}{'frequency'},
				'ip'         => gethostbyname($item->name()),
				'interfaces' => [ ], # XXX find these out
				'disks'      => [ ], # XXX find these out
				'moid'       => $item->{mo_ref}->{value},
			);
			if(! $tt->process($template,\%vars,$file)){
				do_log(0,"Failed to process template $template\n".$tt->error());
			} else { $cfghosts{$type}{$na}=1; 
				$done{$file}=1;
			}
		}
		if( $config{$type}{"purge"} ) {
			foreach $file ( glob($config{$type}{"cfg_host"}."/*.cfg") ) {
				next if( -d $file );
				unlink $file if(!$done{$file});
			}
		}
	}
	if( $config{'global'}{'guests'} and $config{$type}{"cfg_guest"} 
		and $config{$type}{"tt2_guest"} and $guests ) {
		make_path( $config{$type}{"cfg_guest"} );
		# now export guest cfg files
		%done=();
		do_log(3,"Creating guest config files for $type");
		foreach $item ( @$guests ) {
			my($fn,$na) = identify($item,$config{'nagios'}{'verify'});
			my($ip);
			my($a,$b,$c,$d);
			next if(!$fn);
			next if(!$na);
			do_log(3,"Making $type config file for $fn");
			$file = $config{$type}{"cfg_guest"}."/$fn.cfg";
			$template = $config{$type}{"tt2_guest"};
			$ccr = find_cluster($item->resourcePool);
			$dc = find_datacenter($ccr); # should be cached
			$ip = $item->guest->ipAddress;
			if(!$ip) { # in case its down
				$ip = gethostbyname($fn) ;
				if(!$ip) {
					$ip="127.0.0.1";
				} else {
					($a,$b,$c,$d) = unpack('C4',$ip);
					if($a) { $ip="$a.$b.$c.$d"; }
					else { $ip="127.0.0.1"; }
				}
			}
			next if($cfghosts{$type}{$na});
			next if($ip eq '127.0.0.1'); # Ignore guests that cannot be found
			my($host) = $item->runtime->host;
			if($host) {
				$host = getview($host)->name;
			} else { $host = ''; }
			%vars = (
				'this' => $item,
				'name' => $na,
				'fqdn' => $fn,
				'cluster' => ($ccr?('ccr_'.cleanup($ccr->name())):''),
				'datacenter' => ($dc?('dc_'.cleanup($dc->name())):''),
				'interval' => $config{'global'}{'frequency'},
				'ip'   => $ip,
				'interfaces' => $item->{devices_net}, 
				'disks' => $item->{devices_hd},
				'moid' => $item->{mo_ref}->{value},
				'desc' => $item->{devices_desc},
				'host' => $host,
			);
			if(! $tt->process($template,\%vars,$file)){
				do_log(0,"Failed to process template $template\n".$tt->error());
			} else {
				$cfghosts{$type}{$na} = 1; 
				$done{$file}=1;
			}
		}
		if( $config{$type}{"purge"} ) {
			foreach $file ( glob($config{$type}{"cfg_guest"}."/*.cfg") ) {
				next if( -d $file );
				unlink $file if(!$done{$file});
			}
		}
	}
}
sub write_cfg() {
	do_log(2,"Creating configuration files if necessary");
	do_log(3,"MRTG: enable:".$config{'mrtg'}{'enable'}." cfg:".$config{mrtg}{cfg});
	if( $config{'mrtg'}{'enable'} and $config{mrtg}{cfg} ) {
		write_cfg_type('mrtg');
	}
	do_log(3,"Nagios: enable:".$config{'nagios'}{'enable'}." cfg:".$config{nagios}{cfg});
	if( $config{'nagios'}{'enable'} and $config{nagios}{cfg} ) {
		write_cfg_type('nagios');
	}
}
#############################################################################
# MAIN

if($ARGV[0] and ($ARGV[0] !~ /^-/)) {
	$CFGFILE = shift @ARGV;
}

initialise();
print "Using configuration file $CFGFILE\n" if($DEBUG);

# If we're a daemon and not in debug mode, disassociate
if( $config{'global'}{'daemon'} and !$DEBUG ) {
	# print "Daemonising... goodbye!\n";
	open(STDIN, "< /dev/null") || die "can't read /dev/null: $!";
	open(STDOUT, "> /dev/null") || die "can't write to /dev/null: $!";
	defined(my $pid = fork()) || die "can't fork: $!";
	exit(0) if $pid; # non-zero now means I am the parent
	(setsid() != -1) || die "Can't start a new session: $!";
	open(STDERR, ">&STDOUT") || die "can't dup stdout: $!";
}

# Create the PID file
write_pidfile()
	if( $config{'global'}{'daemon'} and $config{'global'}{'pidfile'} );

do {
	$livestatuserr = 0;
	$duplivestatuserr = 0;

	$start = time();
	do_log(2,"Processing starts ".localtime());

	fetch_data();

	write_cfg();

	do_update();

	clear_data(); # free up the memory

	if( $config{'global'}{'frequency'} and $config{'global'}{'daemon'} ) {
		$delay = $config{'global'}{'frequency'} - (time - $start);
		if( $delay > 0 ) {
			do_log(2,"Cycle complete, sleeping for $delay seconds...");
			alarm(0);
			sleep( $delay );
		} else {
			do_log(1,"Overran execution window by ".(0-$delay)." sec");
		}
		if( $has_logfile ) {
		  if($config{'logfile:rotate'} eq 'y' ) {
			close LOGFILE;
			rename $config{'logfile'}{'file'},$config{'logfile'}{'file'}.".old";
			open LOGFILE,(">".$config{'logfile'}{'file'}) or do {
				do_log(0,"Unable to open logfile '".$config{'logfile'}{'file'}."'\n$!");
				exit 2;
			};
			print LOGFILE "---- Opening logfile ".localtime()."\n";
			select LOGFILE; $|=32; select stdout;
		  } elsif($config{'logfile:rotate'} eq 'd') {
			# daily rotation
		  }
		}
	}
} while( $config{'global'}{'daemon'} );

do_log(0,"VMWare Agent shutting down.");
exit(0);
