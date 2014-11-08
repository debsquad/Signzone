#!/bin/ksh

# Copyright (c) 2014, Vincent Tantardini
# All rights reserved.

# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
# 3. All advertising materials mentioning features or use of this software
#    must display the following acknowledgement:
#    This product includes software developed by the <organization>.
# 4. Neither the name of the <organization> nor the
#    names of its contributors may be used to endorse or promote products
#    derived from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY <COPYRIGHT HOLDER> ''AS IS'' AND ANY
# EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL <COPYRIGHT HOLDER> BE LIABLE FOR ANY
# DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

# Signzone 0.1

# Signzone is a simple script that will sign (DNSSEC) the DNS zone file of a
# given domain name after auto-incrementing its serial number. If necessary keys
# has not yet been created, generate and import them in their respective zone
# file before signature.
#
# IMPORTANT: zone files must be named as follows: domain.zone

version="0.1"

usage="Usage: signzone -d domain [-k keysdir] [-z zonedir] [-o file]
                [-r {nsd|named}]
       -d define the domain you want to protect
       -k define the keys directory
       -o use this file to store the signed key
       -r reload specified daemon config
       -z define the zone directory"


################################################################################
# Options
################################################################################

zonedirDEFAULT='/var/nsd/zones/master/'
keysdirDEFAULT='/var/nsd/keys/'
algorithm='RSASHA1_NSEC3'
KSKbits=4096
ZSKbits=2048
reload=0
daemon=
domain=
keysdir=
zonedir=

testPrevCmd() {
  if [ $? -eq 0 ]; then
      printf '%s\n' 'ok'
  else
      echo "failed"
      exit 1
  fi
}

# Options
while getopts "hvd:k:o:r:z:" opt; do
  case "$opt" in
    d)  domain=$OPTARG
        ;;
    k)  keysdir=$OPTARG
        keysdir=$(echo $keysdir | sed 's/\/$//')
        keysdir=$keysdir/
        ;;
    o)  output=$OPTARG
        ;;
    r)  reload=1
        daemon=$OPTARG
        ;;
    z)  zonedir=$OPTARG
        zonedir=$(echo $zonedir | sed 's/\/$//')
        zonedir=$zonedir/
        ;;
    v)  echo "zonesign $version"
        exit
        ;;
    h)  echo "$usage"
        exit
        ;;
    '?')
        echo "/usage" >&2
        exit 1
        ;;
    esac
done
shift "$((OPTIND-1))"

################################################################################
# Controls
################################################################################

# Check if ldns-utils is installed
ldnsSign=$(whereis ldns-signzone)
if [ ! -n "$ldnsSign" ]; then
    echo "Error: ldns-utils not found."
    echo "Please, install ldns-utils from OpenBSD packages or ports."
    exit 1
fi
ldnsKeygen=$(whereis ldns-keygen)

# Checking if domain is set (first arg)
if [ -z $domain ]; then
    echo "Error: required parameter -f is missing."
    echo "$usage"
    exit 1
fi

# Check if -r is set and valid
if [ ! -z $daemon ]; then
    if [[ "$daemon" != "nsd" && "$daemon" != "named" ]]; then
        echo "Error: -r value is invalid."
        echo "$usage"
        exit 1
    fi
fi

# Check if zone directory is set and valid
if [ -z "$zonedir" ]; then
    zonedir=$zonedirDEFAULT
fi
if [ ! -d "$zonedir" ]; then
    echo "Error: zone directory not found."
    exit 1
fi

# Checking if output file is specified
if [ -z $output ]; then
    output=$zonedir/$domain.zone.signed
fi

# Check if zone file is set and valid
ZONE=$zonedir$domain.zone
if [ ! -f "$ZONE" ]; then
    echo "Error: zone file not found."
    exit 1
fi

# Check if keys directory is set and valid
if [ -z "$keysdir" ]; then
    keysdir=$keysdirDEFAULT
fi
if [ ! -d "$keysdir" ]; then
    echo "Error: keys directory not found."
    exit 1
fi
if [ ! -d $keysdir/KSK ]; then
    mkdir $keysdir/KSK
fi
if [ ! -d $keysdir/ZSK ]; then
    mkdir $keysdir/ZSK
fi

################################################################################
# Increment zone serial
################################################################################

printf "Incrementing zone file... "
CURRENTYEAR=$(date "+%Y")
CURRENTDATE=$(date "+%Y%m%d")
ZONESERIAL=$(cat $ZONE | grep $CURRENTYEAR | sed 's/[^0-9]*//g')
ZONEDATE=$(echo $ZONESERIAL | sed 's/[^0-9]*//g' | sed 's/[0-9][0-9]$//')

if [ "$CURRENTDATE" -gt "$ZONEDATE" ]; then
    NEWZONESERIAL="$CURRENTDATE"01
else
    SN=$(echo $ZONESERIAL | sed 's/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]//' \
        | sed 's/^0//')
    ((SN+=1))
    NEWSN=$(printf %02d $SN)
    NEWZONESERIAL=$CURRENTDATE$NEWSN
fi

sed "s/$ZONESERIAL/$NEWZONESERIAL/" $ZONE > /tmp/$domain.zone
cp /tmp/$domain.zone $ZONE
rm /tmp/$domain.zone
printf '%s\n' 'ok'

################################################################################
# Find keys (or create each of them if none exists)
################################################################################

for i in KSK ZSK
do
    printf "Finding $i key... "
    KEY=$(find $keysdir/$i -name "K$domain.+007+*.key" \
        | sed "s:$keysdir/$i/::" | sed 's/[0-9]\+ //;s/.key$//')
    if [ ! -z $KEY ]; then
        eval KEY$i=$KEY
        printf '%s\n' 'ok'
    else
        printf '%s\n' 'not found'
        cd $keysdir$i
        # Generate keys
        if [ "$i" == "KSK" ]; then
            printf "Creating $KSKbits bits $algorithm $i key... "
            $ldnsKeygen -a $algorithm -b $KSKbits -k $domain 1> /dev/null
            testPrevCmd
        else
            printf "Creating $ZSKbits bits $algorithm $i key... "
            $ldnsKeygen -a $algorithm -b $ZSKbits $domain 1> /dev/null
            testPrevCmd
        fi
        # Store key path
        KEY=$(find $keysdir/$i -name "K$domain.+007+*.key" | \
            sed "s:$keysdir/$i/::" | sed 's/[0-9]\+ //;s/.key$//')
        eval KEY$i=$KEY
        # Add key to zone file
	printf "Importing $i key into zone file... "
        echo "\$INCLUDE $keysdir$i/$KEY.key" >> $zonedir$domain.zone
	testPrevCmd
    fi
done

################################################################################
# Sign zone
################################################################################

printf "Signing zone $domain.zone... "
cd $zonedir
$ldnsSign -n -f $output $ZONE $keysdir/KSK/$KEYKSK $keysdir/ZSK/$KEYZSK
testPrevCmd

################################################################################
# Reload DNS daemon infos regarding this zone
################################################################################

if [ $reload == 1 ] ; then
    if [ $daemon == 'nsd' ]; then
        NSDCONTROL=$(whereis nsd-control)
        printf "Refreshing NSD daemon... "
        $NSDCONTROL reload $domain > /dev/null
        testPrevCmd
    elif [ $daemon == 'named' ]; then
        NAMEDCONTROL=/etc/rc.d/named
        printf "Reloading Named daemon... "
        $NAMEDCONTROL reload > /dev/null
        testPrevCmd
    fi
else
    echo "\nDon't forget to reload your DNS daemon to take changes into account."
fi
