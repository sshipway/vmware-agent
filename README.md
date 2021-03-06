# vmware-agent

Steve Shipway s.shipway@auckland.ac.nz 2013

This agent monitors a VMWare VirtualCentre, sending status updates to Nagios
via livestatus and to MRTG via rrdcached.  Memory requirements may be rather 
high if you have a big infrastructure.  Try 8GB.

Configure using the vmware-agent.cfg file in the current directory.  All 
options in the cfg file can also be specified on the command line as
-section:option=value or, if in the [global] section, as -option=value

EG:
./vmware-agent.pl --debug=1 --daemon=1 --logfile:level=4

In daemon mode it will run every 5min by default.

The nagios/nagios-log.cfg file contains a Nagios host/service definition to use
if you want to activate the status logging to Nagios.  This causes any 
agent errors and warnings to be sent to the Nagios/VMWareAgent service so that
Nagios can alert on them.  Note that, for the freshness checks to work, you
need to define a checkcommand 'critical' that always returns status 2.

If you enable the option to generate cfg files, then you will need to set your 
Nagios to read them using the cfg_dir option in the nagios.cfg.

The templates for the generated Nagios and MRTG config files are under the tt2 
directory, and are in TT2 format.

If you dont have MRTG, set enable=false in the [mrtg] section. To use MRTG,
you MUST have rrdcached; preferably v1.4.trunk or later since then we can
create new RRD files automatically via rrdcached.  The generated MRTG config
files assume you are using Routers2 as the frontend to your MRTG/RRD system.
MRTG does not need to process these, but your frontend does.

If you dont have Nagios, set enable=false in the [nagios] section; this also
stops you from using livestatus to verify hostnames.  To use Nagios, you
MUST either have the livestatus module installed, 1.1.0 or later, preferably 1.2.0
or later, and the Monitoring::Livestatus perl module, or else you can use
NSCA to send status (not as efficient and prevents verification)

If you have neither Nagios nor MRTG, then you can't use this.  Later versions
may add additional output methods for other monitoring systems.

The pnp4nagios/unknown file contains a PNP4Nagios template to handle all the
various graphs, assuming they have the 'unknown' command linked to them.

The init.d subdir contains an init.d script for RedHat to start this as a
daemon.

### TO DO

* cmd fifo support for Nagios 

* create rrd files via local RRDs

* deal with the rather large memory requirements...

