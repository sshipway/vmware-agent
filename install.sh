#!/bin/sh

BINDIR=/usr/local/sbin
ETCDIR=/usr/local/etc
PNPDIR=/u02/pnp4nagios

echo Installing script to $BINDIR
cp vmware-agent.pl $BINDIR
echo Installing configuration to $ETCDIR
cp vmware-agent.cfg $ETCDIR
echo Installing init script
cp init.d/vmware-agent /etc/init.d
echo Installing logrotate definition
cp logrotate.d/vmware-agent /etc/logrotate.d
echo Copying templates
cp -r tt2 $ETCDIR
echo Creating sysconfig file
echo "CFGFILE=$ETCDIR/vmware-agent.cfg" > /etc/sysconfig/vmware-agent
echo "AGENT=$BINDIR/vmware-agent.pl" >> /etc/sysconfig/vmware-agent
echo "LOGLEVEL=2" >> /etc/sysconfig/vmware-agent
if [ -d $PNPDIR ]
then
  echo Copying pnp4nagios templates
  cp pnp4nagios/*.php $PNPDIR/share/templates/
fi
#if [ `crontab -l | egrep -c vmware-agent` -eq 0 ]
#then
#	echo Setting up crontab
#	crontab -l > /tmp/ct.$$
#	echo "# Check agent running!" >> /tmp/ct.$$
#	echo "30 0 * * * /etc/init.d/vmware-agent start >/dev/null 2>&1" >> /tmp/ct.$$
#	crontab /tmp/ct.$$
#	rm -f /tmp/ct.$$
#else
#	echo Crontab already present
#fi
#echo "(Re-)Starting the agent"
#/etc/init.d/vmware-agent restart
echo Done
exit 0
