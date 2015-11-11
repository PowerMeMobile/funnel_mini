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
    local system_id="${5-${SYSTEM_ID}}"
    local src_addr="${6-${SRC_ADDR}}"
    local dst_addr="${7-${DST_ADDR}}"

    case "$delivery" in
        !dlr) delivery_flag=false;;
        dlr) delivery_flag=true
    esac

    case "$invert" in
        w/o) invert_match="--invert-match";;
        with) invert_match=""
    esac

    echo -n "$src_addr;$dst_addr;$command;$delivery_flag;3" |
    smppload --host=$HOST --port=$PORT --system_type=$SYSTEM_TYPE --system_id=$system_id --password=$PASSWORD --file - -vv | grep $invert_match "$pattern" > /dev/null

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
echo "# Check override originator"
echo "#"

check "empty 375296660001" !dlr w/o "ERROR" user 375296660001
check "empty ''          " !dlr w/o "ERROR" user ""
check "empty 375296660099" !dlr with "Invalid Source Address" user 375296660099

check "any 375296660001" !dlr w/o "ERROR" user2 375296660001
check "any ''          " !dlr w/o "ERROR" user2 ""
check "any 375296660099" !dlr w/o "ERROR" user2 375296660099

check "false 375296660001" !dlr w/o "ERROR" user3 375296660001
check "false ''         "  !dlr with "Invalid Source Address" user3 ""
check "false 375296660099" !dlr with "Invalid Source Address" user3 375296660099

echo "#"
echo "# Check originator routing"
echo "#"

echo "# override originator: empty"
# if source is NOT given use default
check "receipt:accepted # default should succ" dlr with "stat:ACCEPTD" user "" 375296660000
check "receipt:accepted # default should succ" dlr with "stat:ACCEPTD" user "" 999296660000
check "receipt:accepted # default should fail" dlr with "Invalid Destination Address" user "" 888296660000

check "receipt:accepted # default should succ" dlr with "stat:ACCEPTD" user 375296660001 375296660000
check "receipt:accepted # default should succ" dlr with "stat:ACCEPTD" user 375296660001 999296660000
check "receipt:accepted # default should fail" dlr with "Invalid Destination Address" user 375296660001 888296660000

check "receipt:accepted # sims should succ" dlr with "stat:ACCEPTD" user "sims,5,0" 375296660000
check "receipt:accepted # sims should succ" dlr with "stat:DELIVRD" user "sims,5,0" 999296660000
check "receipt:accepted # sims should fail" dlr with "Invalid Destination Address" user "sims,5,0" 888296660000

echo "# override originator: any"
# route on source if given
check "receipt:accepted # default should succ" dlr with "stat:ACCEPTD" user2 "" 375296660000
check "receipt:accepted # default should succ" dlr with "stat:ACCEPTD" user2 "" 999296660000
check "receipt:accepted # default should fail" dlr with "Invalid Destination Address" user2 "" 888296660000

check "receipt:accepted # default should succ" dlr with "stat:ACCEPTD" user2 375296660001 375296660000
check "receipt:accepted # default should succ" dlr with "stat:ACCEPTD" user2 375296660001 999296660000
check "receipt:accepted # default should fail" dlr with "Invalid Destination Address" user2 375296660001 888296660000

check "receipt:accepted # sims should succ" dlr with "stat:ACCEPTD" user2 "sims,5,0" 375296660000
check "receipt:accepted # sims should succ" dlr with "stat:DELIVRD" user2 "sims,5,0" 999296660000
check "receipt:accepted # sims should fail" dlr with "Invalid Destination Address" user2 375296660001 888296660000

echo "# override originator: false"
# use whatever source given
check "receipt:accepted # default should succ" dlr with "stat:ACCEPTD" user3 375296660001 375296660000
check "receipt:accepted # default should succ" dlr with "stat:ACCEPTD" user3 375296660001 999296660000
check "receipt:accepted # default should fail" dlr with "Invalid Destination Address" user3 375296660001 888296660000

check "receipt:accepted # sims should succ" dlr with "stat:ACCEPTD" user3 "sims,5,0" 375296660000
check "receipt:accepted # sims should succ" dlr with "stat:DELIVRD" user3 "sims,5,0" 999296660000
check "receipt:accepted # sims should fail" dlr with "Invalid Destination Address" user3 "sims,5,0" 888296660000

echo "#"
echo "# Check blocklist"
echo "#"

check "blocklisted w/o space" !dlr with "ERROR: Failed with: (0x00000400)" user 375296660001 375296666666
check "blocklisted w/ spaces" !dlr with "ERROR: Failed with: (0x00000400)" user 375296660001 ' 375296666666  '
check "blocklisted w/ linefeed" !dlr with "ERROR: Failed with: (0x00000400)" user 375296660001 `echo '375296666666\n'`

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
