#!/usr/bin/env bash

# This file tries to smooth over the differences between GNU and BSD userlands.
#
# It's meant to be 'source'd from scripts that actually try to do something
# useful.


# adjtime TIMESTAMP [+-]HOURS
#
# POSIX date is useless, and BSD and GNU made it useful in annoyingly
# incompatible ways.  We define a function that takes a base UNIX timestamp and
# a +/- hour adjustment, and returns a string in the form of '2016-07-22-H02'

if uname -a | grep '\bGNU/' &>/dev/null ; then
  adjdate() {
    # GNU date has '@TIMESTAMP', but you can't apply adjustments to it.
    ADJUSTED=$(($1 + (3600 * $2)))
    date -u --date="@$ADJUSTED" '+%Y-%m-%d-H%H'
  }
else
  adjdate() {
    # Add a '+' before non-negative numbers
    ADJUSTED=$(echo "$2" | sed -e 's/^\([0-9]\)/+\1/')
    date -u -j -r "$1" -v"$ADJUSTED"H '+%Y-%m-%d-H%H'
  }
fi
