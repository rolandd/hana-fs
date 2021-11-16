#!/bin/bash

# Copyright 2021 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Usage:
#   hana-fs.sh <sanlun show output file> <multipath -l output file>
#
# This script consumes output files from "sanlun lun show" and "multipath
# -l" and outputs a set of commands to run to set up HANA storage.  The
# idea is to wrap this script in a smaller script that collects the input
# and optionally runs the output, so that the logic in this script can also
# be tested by checking the output for known input.

set -e

usage () {
  cat <<EOS 1>&2
Usage: $0 <sanlun show output file> <multipath -l output file>
EOS
}

if [ $# -ne 2 ]; then
  usage
  exit 1
fi

SANLUNOUT=$1
MULTIPATHOUT=$2

# Get the set of multipath devices associated to NetApp LUNS

if ! head -1 $SANLUNOUT | grep -qs -E '^controller.*device.*host.*lun'; then
  echo 1>&2 Error: $SANLUNOUT does not appear to be \'sanlun lun show\' output
  usage
  exit 1
fi

if ! head -1 $MULTIPATHOUT | grep -qs -E '^[a-f0-9]+ dm-[0-9]+'; then
  echo 1>&2 Error: $MULTIPATHOUT does not appear to be \'multipath -l\' output
  usage
  exit 1
fi

#
# Expected layout:
#
#   hanadatavg / data     - 4 x 10TB striped devices
#   hanalogvg / log       - 4 x 768GB striped devices
#   hanasharedvg / shared - 1 x 3TB device (not striped)
#

# Parse sanlun output

declare -A dataluns
declare -A logluns
sharedlun=

while read dev vol size; do
  case "$size" in
    *g)
      size=${size%g}
      size=${size%.[0-9]}
      if [ $size -ge 764 -a $size -le 772 ]; then
        logluns[$dev]=$vol
      fi
      ;;
    *t)
      size=${size%t}
      size=${size%.[0-9]}
      if [ $size -eq 10 ]; then
        dataluns[$dev]=$vol
      elif [ $size -eq 3 ]; then
        if [ -n "$sharedlun" ]; then
          echo 1>&2 "Error: Multiple 3T candidates for 'shared' volume"
          echo 1>&2 "  $sharedlun"
          echo 1>&2 "  $vol"
          exit 1
        fi
        sharedlun=$vol
        shareddev=$dev
      fi
      ;;
  esac
done < <( awk '/vol/ {print $3,$2,$6}' $SANLUNOUT | \
  sort -k2 | \
  uniq -f1 )

if [ ${#logluns[@]} -ne 4 ]; then
  echo 1>&2 "Error: need 4 x 768G LUNs for 'log' volume, found:"
  for i in ${logluns[@]}; do
    echo 1>&2 "  $i"
  done
  exit 1
fi

if [ ${#dataluns[@]} -ne 4 ]; then
  echo 1>&2 "Error: need 4 x 10T LUNs for 'data' volume, found:"
  for i in ${dataluns[@]}; do
    echo 1>&2 "  $i"
  done
  exit
fi

if [ -z sharedlun ]; then
  echo 1>&2 "Error: no 3T LUN found for 'shared' volume"
  exit 1
fi

declare -A dmpaths
dmid=

# Parse multipath map
while IFS= read mpline; do
  case "$mpline" in
    # 3600a098038314453783f507430687431 dm-14 NETAPP,LUN C-Mode
    [a-f0-9]*dm-[0-9]*)
      dmdev=${mpline%%\ *}
      ;;

    # | |- 14:0:1:20 sdar 66:176  active undef running
    *[0-9]:*[0-9]:*[0-9]:*[0-9]\ *sd*)
      sddev=/dev/sd${mpline##*\ sd}
      sddev=${sddev%%\ *}
      dmpaths[$sddev]=$dmdev
      ;;
  esac
done < $MULTIPATHOUT

logpvs=
for i in ${!logluns[@]}; do
  echo pvcreate /dev/mapper/${dmpaths[$i]}
  logpvs="$logpvs /dev/mapper/${dmpaths[$i]}"
done

datapvs=
for i in ${!dataluns[@]}; do
  echo pvcreate /dev/mapper/${dmpaths[$i]}
  datapvs="$datapvs /dev/mapper/${dmpaths[$i]}"
done

echo pvcreate /dev/mapper/${dmpaths[$shareddev]}
sharedpv=/dev/mapper/${dmpaths[$shareddev]}

echo

echo vgcreate hanalogvg $logpvs
echo vgcreate hanadatavg $datapvs
echo vgcreate hanasharedvg $sharedpv

echo

echo lvcreate --name log --stripes 4 --stripesize 64 --extents 100%FREE hanalogvg
echo lvcreate --name data --stripes 4 --stripesize 64 --extents 100%FREE hanadatavg
echo lvcreate --name shared --extents 100%FREE hanasharedvg

echo

echo mkfs.xfs -f /dev/mapper/hanalogvg-log
echo mkfs.xfs -f /dev/mapper/hanadatavg-data
echo mkfs.xfs -f /dev/mapper/hanasharedvg-shared

echo

echo mkdir -p /hana/log
echo mkdir -p /hana/data
echo mkdir -p /hana/shared

echo

echo mount -o defaults,nofail,logbsize=256k,noatime,nodiratime /dev/mapper/hanalogvg-log /hana/log
echo mount -o defaults,nofail,logbsize=256k,noatime,nodiratime /dev/mapper/hanadatavg-data /hana/data
echo mount -o defaults /dev/mapper/hanasharedvg-shared /hana/shared

echo

echo grep hanalog /etc/mtab \>\> /etc/fstab
echo grep hanadata /etc/mtab \>\> /etc/fstab
echo grep hanashared /etc/mtab \>\> /etc/fstab

exit 0
