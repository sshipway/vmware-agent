#!/bin/sh
GUEST=guestname
DIR=/usr/local/src/vmware-agent
CFG=/usr/local/etc/vmware-agent.cfg
if [ "$1" != "" ]
then
	GUEST="$1"
fi
echo One pass run for guest $GUEST
cd $DIR
$DIR/vmware-agent.pl "$CFG" --test=1 --debug=2 --daemon=0 --clusters=0 --datacenters=0 --hosts=0 --logfile:file=$DIR/vmware-agent.log --logfile:append=0 --logfile:level=4 --logfile:rotate=0 --guests:match="$GUEST" --nagios:verify=0 --nagios:cfg=0 --mrtg:cfg=0 | more


