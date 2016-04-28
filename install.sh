#!/bin/sh

cp vmware-agent.pl /usr/local/sbin
cp vmware-agent.cfg /usr/local/etc
cp init.d/vmware-agent /etc/init.d
cp logrotate.d/vmware-agent /etc/logrotate.d
cp -r tt2 /usr/local/etc

echo "CFGFILE=/usr/local/etc/vmware-agent.cfg" > /etc/sysconfig/vmware-agent
echo "AGENT=/usr/local/sbin/vmware-agent.pl" >> /etc/sysconfig/vmware-agent


