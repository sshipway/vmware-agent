<?php

####################################################################
# Template for PNP4Nagios graphing of vmware-agent
#
# This template is for the metrics in the perfdata produced by
# the vmware-agent script.  You need to store it in a file corresponding
# to the name of the checkcommand, which may be 'unknown' as this
# is used by freshness checking to set the status to unknown if the
# agent is not running.
#
# S Shipway, 2013, The University of Auckland
####################################################################

$_WARNRULE = '#FFFF00';
$_CRITRULE = '#FF0000';
$_AREA     = '#256aef';
$_LINE     = '#000000';

switch ( $NAGIOS_AUTH_SERVICEDESC ) {
#######################################################################
# VMware: CPU

case "VMware: Host CPU":
$opt[1] = "--vertical-label \"percent\" --title \"CPU Usage $hostname \" --lower=0 ";
$def[1] =  "DEF:var1=$RRDFILE[1]:$DS[1]:AVERAGE " ;
$def[1] .= "AREA:var1#0000FF:\"CPU used\"  ";
$def[1] .= rrd::gprint("var1", array("LAST","MAX","AVERAGE"), "%5.2lf %%");
break;

case "VMware: CPU":

if( count($DS) > 1 ) {

# VMware CPU graphs
# 1 = CPU in MHz (DS2)
# 2 = Percentage split used/ready/sys (DS3/4/5 with total and thresholds)

$opt[1] = "--vertical-label \"Hz\" --title \"CPU Usage $hostname \" --lower=0 ";
$def[1] =  "DEF:var1=$RRDFILE[2]:$DS[2]:AVERAGE " ;
$def[1] .= rrd::gradient("var1", "66CCFF", "0000ff", "CPU"); 
$def[1] .= "LINE1:var1#666666 " ;
if($CRIT[2]) {
$def[1] .= rrd::hrule($CRIT[2], $_CRITRULE, "Critical ".round($CRIT[2]/1000000)."MHz \\n");
}
$def[1] .= rrd::gprint("var1", array("LAST","MAX","AVERAGE"), "%6.2lf %sHz");

if( count($DS) > 4 ) {
$opt[2] = "--vertical-label \"percent\" --title \"CPU Usage $hostname \" --lower=0 ";
$def[2] =  "DEF:var1=$RRDFILE[3]:$DS[3]:AVERAGE " ;
$def[2] .= "DEF:var2=$RRDFILE[4]:$DS[4]:AVERAGE " ;
$def[2] .= "DEF:var3=$RRDFILE[5]:$DS[5]:AVERAGE " ;
$def[2] .= "DEF:var4=$RRDFILE[1]:$DS[1]:AVERAGE " ;
$def[2] .= "AREA:var1#00C000:\"Used time  \"  ";
$def[2] .= rrd::gprint("var1", array("LAST","MAX","AVERAGE"), "%5.2lf %%");
$def[2] .= "AREA:var2#FF8080:\"Ready time \":STACK  ";
$def[2] .= rrd::gprint("var2", array("LAST","MAX","AVERAGE"), "%5.2lf %%");
$def[2] .= "AREA:var3#0000C0:\"System time\":STACK  ";
$def[2] .= rrd::gprint("var3", array("LAST","MAX","AVERAGE"), "%5.2lf %%");
$def[2] .= "LINE1:var4#666666:\"Average usage\" " ;
$def[2] .= rrd::gprint("var4", array("LAST","MAX","AVERAGE"), "%5.2lf %%");
if( $CRIT[1] ) {
$def[2] .= rrd::hrule($CRIT[1], $_CRITRULE, "Critical ".$CRIT[1]." %\\n");
}
}
} else {

$opt[1] = "--vertical-label \"percent\" --title \"CPU Usage $hostname \" --lower=0 ";
$def[1] =  "DEF:var1=$RRDFILE[1]:$DS[1]:AVERAGE " ;
$def[1] .= "AREA:var1#0000FF:\"CPU used\"  ";
$def[1] .= rrd::gprint("var1", array("LAST","MAX","AVERAGE"), "%5.2lf %%");

}

break;

#######################################################################
# VMware: Memory

case "VMware: Host Memory":
$opt[1] = "--vertical-label \"percent\" --title \"Physical Memory Usage $hostname \" --lower=0 ";
$def[1] =  "DEF:var1=$RRDFILE[1]:$DS[1]:AVERAGE " ;
$def[1] .= "AREA:var1#0000FF:\"Memory used\"  ";
$def[1] .= rrd::gprint("var1", array("LAST","MAX","AVERAGE"), "%5.2lf %%");


if( count($DS) > 2 ) {
$opt[2] = "--vertical-label \"Activity\" --title \"Swap activity $hostname \" --lower=0 ";
$def[2] =  "DEF:var1=$RRDFILE[2]:$DS[2]:AVERAGE " ;
$def[2] .= "DEF:var2=$RRDFILE[3]:$DS[3]:AVERAGE " ;
$def[2] .= "LINE1:var1#00CC00:\"Swap in \" " ;
$def[2] .= rrd::gprint("var1", array("LAST","MAX","AVERAGE"), "%5.2lf %sB/s");
$def[2] .= "LINE1:var2#0000CC:\"Swap out\" " ;
$def[2] .= rrd::gprint("var2", array("LAST","MAX","AVERAGE"), "%5.2lf %sB/s");
}
break;

case "VMware: Memory":

# VMware Memory graphs
# 1 = memory used DS1, with active overlaid DS2
# 2 = stacked private/shared/balloon/swap DS4,5,3,6
# 3 = swap in/out activity DS7,8

if( count($DS) > 1 ) {
$opt[1] = "--vertical-label \"Memory\" --title \"Memory Usage $hostname \" --lower=0 ";
$def[1] =  "DEF:var1=$RRDFILE[1]:$DS[1]:AVERAGE " ;
$def[1] .= "DEF:var2=$RRDFILE[2]:$DS[2]:AVERAGE " ;
$def[1] .= rrd::gradient("var1", "66CCFF", "0000ff", "Memory"); 
$def[1] .= rrd::gprint("var1", array("LAST","MAX","AVERAGE"), "%6.2lf %sB");
$def[1] .= "LINE1:var2#666666:\"Active\" " ;
$def[1] .= rrd::gprint("var2", array("LAST","MAX","AVERAGE"), "%6.2lf %sB");

if( count($DS) > 5 ) {
$opt[2] = "--vertical-label \"percent\" --title \"Virtual Memory $hostname \" --lower=0 ";
$def[2] =  "DEF:var1=$RRDFILE[4]:$DS[4]:AVERAGE " ;
$def[2] .= "DEF:var2=$RRDFILE[5]:$DS[5]:AVERAGE " ;
$def[2] .= "DEF:var3=$RRDFILE[3]:$DS[3]:AVERAGE " ;
$def[2] .= "DEF:var4=$RRDFILE[6]:$DS[6]:AVERAGE " ;
$def[2] .= "CDEF:pvar1=var1,100,*,$MAX[1],/ ";
$def[2] .= "CDEF:pvar2=var2,100,*,$MAX[1],/ ";
$def[2] .= "CDEF:pvar3=var3,100,*,$MAX[1],/ ";
$def[2] .= "CDEF:pvar4=var4,100,*,$MAX[1],/ ";
$def[2] .= "AREA:pvar1#0000FF:\"Private memory\"  ";
$def[2] .= rrd::gprint("pvar1", array("LAST","MAX","AVERAGE"), "%5.2lf %%");
$def[2] .= "AREA:pvar2#8080FF:\"Shared memory \":STACK  ";
$def[2] .= rrd::gprint("pvar2", array("LAST","MAX","AVERAGE"), "%5.2lf %%");
$def[2] .= "AREA:pvar3#C0C000:\"Balloon Memory\":STACK  ";
$def[2] .= rrd::gprint("pvar3", array("LAST","MAX","AVERAGE"), "%5.2lf %%");
$def[2] .= "AREA:pvar4#FF0000:\"Swapped memory\":STACK " ;
$def[2] .= rrd::gprint("pvar4", array("LAST","MAX","AVERAGE"), "%5.2lf %%");

$opt[3] = "--vertical-label \"Swapping\" --title \"ESX Swapping $hostname \" --lower=0 ";
$def[3] =  "DEF:var1=$RRDFILE[7]:$DS[7]:AVERAGE " ;
$def[3] .= "DEF:var2=$RRDFILE[8]:$DS[8]:AVERAGE " ;
$def[3] .= "LINE1:var1#00C000:\"Swap in \" " ;
$def[3] .= rrd::gprint("var1", array("LAST","MAX","AVERAGE"), "%6.2lf %sB/s");
$def[3] .= "LINE1:var2#0000C0:\"Swap out\" " ;
$def[3] .= rrd::gprint("var2", array("LAST","MAX","AVERAGE"), "%6.2lf %sB/s");
}
} else {

$opt[1] = "--vertical-label \"percent\" --title \"Physical Memory Usage $hostname \" --lower=0 ";
$def[1] =  "DEF:var1=$RRDFILE[1]:$DS[1]:AVERAGE " ;
$def[1] .= "AREA:var1#0000FF:\"Memory used\"  ";
$def[1] .= rrd::gprint("var1", array("LAST","MAX","AVERAGE"), "%5.2lf %%");

}

break;
#######################################################################
# DEFAULT ACTION
default:

# This is a copy of default.php

foreach ($this->DS as $KEY=>$VAL) {

	$maximum  = "";
	$minimum  = "";
	$critical = "";
	$crit_min = "";
	$crit_max = "";
	$warning  = "";
	$warn_max = "";
	$warn_min = "";
	$vlabel   = " ";
	$lower    = "";
	$upper    = "";
	
	if ($VAL['WARN'] != "" && is_numeric($VAL['WARN']) ){
		$warning = $VAL['WARN'];
	}
	if ($VAL['WARN_MAX'] != "" && is_numeric($VAL['WARN_MAX']) ) {
		$warn_max = $VAL['WARN_MAX'];
	}
	if ( $VAL['WARN_MIN'] != "" && is_numeric($VAL['WARN_MIN']) ) {
		$warn_min = $VAL['WARN_MIN'];
	}
	if ( $VAL['CRIT'] != "" && is_numeric($VAL['CRIT']) ) {
		$critical = $VAL['CRIT'];
	}
	if ( $VAL['CRIT_MAX'] != "" && is_numeric($VAL['CRIT_MAX']) ) {
		$crit_max = $VAL['CRIT_MAX'];
	}
	if ( $VAL['CRIT_MIN'] != "" && is_numeric($VAL['CRIT_MIN']) ) {
		$crit_min = $VAL['CRIT_MIN'];
	}
	if ( $VAL['MIN'] != "" && is_numeric($VAL['MIN']) ) {
		$lower = " --lower=" . $VAL['MIN'];
		$minimum = $VAL['MIN'];
	}
	if ( $VAL['MAX'] != "" && is_numeric($VAL['MAX']) ) {
		$maximum = $VAL['MAX'];
	}
	if ($VAL['UNIT'] == "%%") {
		$vlabel = "%";
		$upper = " --upper=101 ";
		$lower = " --lower=0 ";
	}
	else {
		$vlabel = $VAL['UNIT'];
	}

	$opt[$KEY] = '--vertical-label "' . $vlabel . '" --title "' . $this->MACRO['DISP_HOSTNAME'] . ' / ' . $this->MACRO['DISP_SERVICEDESC'] . '"' . $upper . $lower;
	$ds_name[$KEY] = $VAL['LABEL'];
	$def[$KEY]  = rrd::def     ("var1", $VAL['RRDFILE'], $VAL['DS'], "AVERAGE");
	$def[$KEY] .= rrd::gradient("var1", "3152A5", "BDC6DE", rrd::cut($VAL['NAME'],16), 20);
	$def[$KEY] .= rrd::line1   ("var1", $_LINE );
	$def[$KEY] .= rrd::gprint  ("var1", array("LAST","MAX","AVERAGE"), "%3.4lf %S".$VAL['UNIT']);
	if ($warning != "") {
		$def[$KEY] .= rrd::hrule($warning, $_WARNRULE, "Warning  $warning \\n");
	}
	if ($warn_min != "") {
		$def[$KEY] .= rrd::hrule($warn_min, $_WARNRULE, "Warning  (min)  $warn_min \\n");
	}
	if ($warn_max != "") {
		$def[$KEY] .= rrd::hrule($warn_max, $_WARNRULE, "Warning  (max)  $warn_max \\n");
	}
	if ($critical != "") {
		$def[$KEY] .= rrd::hrule($critical, $_CRITRULE, "Critical $critical \\n");
	}
	if ($crit_min != "") {
		$def[$KEY] .= rrd::hrule($crit_min, $_CRITRULE, "Critical (min)  $crit_min \\n");
	}
	if ($crit_max != "") {
		$def[$KEY] .= rrd::hrule($crit_max, $_CRITRULE, "Critical (max)  $crit_max \\n");
	}
	$def[$KEY] .= rrd::comment("Default Template\\r");
	$def[$KEY] .= rrd::comment("Command " . $VAL['TEMPLATE'] . "\\r");

} # end foreach

} # end case

?>
