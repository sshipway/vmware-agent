#!/bin/sh
# Test livestatus looking for a host!

TMP=/tmp/foo.$$
NAGIOS=localhost
HOST=Nagios
if [ "$1" = "-H" ]
then	
	shift
	NAGIOS=$1
	shift
fi
if [ "$1" != "" ]
then
	HOST=$1
fi
cat <<_END_ > $TMP
GET hosts
Columns: address alias state
Filter: host_name = $HOST

_END_
echo "Connecting to $NAGIOS:6557"
cat $TMP
echo ".----------------------------------------------------------------"
cat $TMP| nc $NAGIOS 6557
echo ".----------------------------------------------------------------"
echo Exit status is $?
rm -f $TMP
exit 0
