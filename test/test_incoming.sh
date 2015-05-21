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
SYSTEM_TYPE=''
SYSTEM_ID=user
PASSWORD=password
SRC_ADDR=375296660001
DST_ADDR=999296543210
SHORT_CODE_ADDR=0011

SMPPSIM_SERVER="http://${SMPPSIM_HOST-$HOST}:${SMPPSIM_PORT-8071}"

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
    smppload --host=$HOST --port=$PORT --system_type=$SYSTEM_TYPE --system_id=$SYSTEM_ID --password=$PASSWORD \
        --file - -vv | grep $invert_match "$pattern" > /dev/null

    if [[ "$?" != 0 ]]; then
        echo -e "$command\t$delivery\t\e[31mFAIL\e[0m"
        EXIT=1
    else
        echo -e "$command\t$delivery\t\e[32mOK\e[0m"
    fi
}

function send_incoming_via_smppsim() {
    local src="$1"
    local dst="$2"
    local msg="$3"

    local url="$SMPPSIM_SERVER/inject_mo?\
short_message=$msg&\
source_addr=$src&\
source_addr_ton=1&source_addr_npi=1&\
destination_addr=$dst&\
dest_addr_ton=6&dest_addr_npi=0"

    curl -s "$url" > /dev/null
}

echo "#"
echo "# Clean up"
echo "#"

cleanup

echo "#"
echo "# Check incomings"
echo "#"

B=$RANDOM; send_incoming_via_smppsim $DST_ADDR $SHORT_CODE_ADDR $B; check "dummy" dlr with "{short_message,\"$B\"}"

exit $EXIT
