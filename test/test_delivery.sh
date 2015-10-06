#!/bin/bash

#
# You need SMPPSim (http://www.seleniumsoftware.com/user-guide.htm),
# smppsink (https://github.com/PowerMeMobile/smppsink) and
# smppload (https://github.com/PowerMeMobile/smppload) to run these tests,
# as well as a correctly configured customer and its coverage map.
# See https://github.com/PowerMeMobile/alley-setup/ for more details.
#

HOST=${FUNNEL_HOST-127.0.0.1}
PORT=${FUNNEL_PORT-2775}
SYSTEM_TYPE=10001
SYSTEM_ID=user
PASSWORD=password
SRC_ADDR=375296660001
DST_ADDR=375296543210

EXIT=0

function cleanup() {
    # this will bind only and hopefully receive left receipts/incomings.
    smppload --host=$HOST --port=$PORT --system_type=$SYSTEM_TYPE --system_id=$SYSTEM_ID --password=$PASSWORD --bind_type=RX -v0 --delivery_timeout=5000
}

function check() {
    local command="$1"
    local delivery="$2"
    local invert="$3"
    local pattern="$4"
    local encoding="${5-3}" # default latin1

    case "$delivery" in
        !dlr) delivery_flag=false;;
        dlr) delivery_flag=true
    esac

    case "$invert" in
        w/o) invert_match="--invert-match";;
        with) invert_match=""
    esac

    echo -n "$SRC_ADDR;$DST_ADDR;$command;$delivery_flag;$encoding" |
    smppload --host=$HOST --port=$PORT --system_type=$SYSTEM_TYPE --system_id=$SYSTEM_ID --password=$PASSWORD --file - -vv | grep $invert_match "$pattern" > /dev/null

    if [[ "$?" != 0 ]]; then
        echo -e "$command\t$delivery\t\e[31mFAIL\e[0m"
        EXIT=1
    else
        echo -e "$command\t$delivery\t\e[32mOK\e[0m"
    fi
}

echo "#"
echo "# Clean up"
echo "#"

cleanup

echo "#"
echo "# Check delivery statuses"
echo "#"

# standard
check "receipt:enroute"       dlr with "stat:ENROUTE"
check "receipt:delivered"     dlr with "stat:DELIVRD"
check "receipt:expired"       dlr with "stat:EXPIRED"
check "receipt:deleted"       dlr with "stat:DELETED"
check "receipt:undeliverable" dlr with "stat:UNDELIV"
check "receipt:accepted"      dlr with "stat:ACCEPTD"
check "receipt:unknown"       dlr with "stat:UNKNOWN"
check "receipt:rejected"      dlr with "stat:REJECTD"

# non-standard
check "receipt:unrecognized"  dlr with "stat:UNRECOG"
check "receipt:BADSTATUS"     dlr with "stat:UNRECOG"

# check errorneous submit, but with dlr
check "submit:1" dlr with "stat:REJECTD"

exit $EXIT
