#!/bin/sh
# Test livestatus looking for a host!

TMP=/tmp/foo.$$
#NAGIOS=nagcolprd01.its.auckland.ac.nz
NAGIOS=localhost
#HOST=raspi.its
HOST=Nagios
if [ "$1" != "" ]
then
	HOST=$1
fi
cat <<_END_ > $TMP
GET hosts
Columns: address alias state
Filter: host_name = $HOST

_END_
cat $TMP
echo ".----------------------------------------------------------------"
cat $TMP| nc $NAGIOS 6557
echo ".----------------------------------------------------------------"
echo Exit status is $?
rm -f $TMP
exit 0
