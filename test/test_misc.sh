#!/bin/bash

#
# You need SMPPSim (http://www.seleniumsoftware.com/user-guide.htm) and
# smppload (https://github.com/PowerMeMobile/smppload) to run these tests,
# as well as a correctly configured customer and its coverage map.
# See https://github.com/PowerMeMobile/alley-setup/ for more details.
#
# To make the tests run more smoothly use:
# funnel_conf:set(batch_max_wait, 1000).
#

HOST=${FUNNEL_HOST-127.0.0.1}
PORT=${FUNNEL_PORT-2775}
SYSTEM_TYPE=''
SYSTEM_ID=user
PASSWORD=PasSworD
SRC_ADDR=375296660001
DST_ADDR=375296543210

GSM0338=1
ASCII=1
LATIN1=3
UCS2=8

EXIT=0

function cleanup() {
    # this will bind only and hopefully receive left receipts.
    for i in `seq 1 5`; do
        smppload --host=$HOST --port=$PORT --system_type=$SYSTEM_TYPE --system_id=$SYSTEM_ID --password=$PASSWORD -c0 -v0
        sleep 1
    done
}

function check_bind() {
    local password="$1"

    `smppload --host=$HOST --port=$PORT --system_type=$SYSTEM_TYPE --system_id=$SYSTEM_ID --password=$password -c0 -v | grep 'Bound to' > /dev/null`
    if [[ "$?" == 0 ]]; then
        echo -e "$password\t\e[32mOK\e[0m"
    else
        echo -e "$password\t\e[31mFAIL\e[0m"
        EXIT=1
    fi
}

function check() {
    local to="$1"
    local body="$2"
    local encoding="$3"
    local count="$4"
    local parts="$5"

    echo -en "to: $to\tlength: ${#body}\tcount: $count\tparts: $parts == "

    lines=`smppload --host=$HOST --port=$PORT --system_type=$SYSTEM_TYPE --system_id=$SYSTEM_ID --password=$PASSWORD \
        --source=$SRC_ADDR --destination="$to" --body="$body" --count="$count" --delivery --thread_count=5 --data_coding=$encoding -vv | egrep "Receipt.*DELIVRD" | wc -l`

    if [[ "$?" == 0 && $lines == $parts ]]; then
        echo -e "$lines\t\e[32mOK\e[0m"
    else
        echo -e "$lines\t\e[31mFAIL\e[0m"
        EXIT=1
    fi
}

echo "#"
echo "# Clean up"
echo "#"

cleanup

check_bind ${PASSWORD}
check_bind ${PASSWORD,,}
check_bind ${PASSWORD^^}

BODY="\
abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz\
"
TO=${DST_ADDR}
check ${TO} ${BODY} ${LATIN1} 2 4

BODY="\
abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz\
"
TO=375296543:3
check ${TO} ${BODY} ${LATIN1} 2 4

exit $EXIT
