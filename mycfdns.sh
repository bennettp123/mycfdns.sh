#!/bin/bash

USAGE="Usage:
 $(basename $0) -z <zone> -h <fqdn> -e <email> -k <api_key> [-l] [-i <iface>]
 $(basename $0) --help

 -h <fqdn>     : The hostname to update
 -z <zone>     : The zone to update
 -e <email>    : The API authentication email address to use
 -k <key>      : The API authentication key to use
 -l            : Set using local interface address
 -i <iface>    : The interface to use when getting local address. Implies -l

By default, $(basename $0) queries icanhazip.com to determine the public IP address.
When called with -l or -i, it uses the address of a local interface instead.
"

# detect sed syntax
sed_ex_sw='-E' #default
for sw in '-r' '-E'; do
  if echo '123' | sed "$sw" 's/1(2)3/\1/' 2>&1 | grep --silent 2; then
    sed_ex_sw="$sw"
    break
  fi
done

fqdn=''
zone=''
authEmail=''
authKey=''
use_local_iface_address='' # set this to 'yes' to use ifconfig to determine local IP addresses.
iface='eth0' # ignored unless $use_local_iface_address = yes

if [ "$1" == "--help" ]; then
  printf "%s\n" "$USAGE"
  exit 0
fi

while getopts 'h:z:e:k:li:h' optname; do
  case "$optname" in
    'h')
      fqdn="$OPTARG"
      ;;
    'z')
      zone="$OPTARG"
      ;;
    'e')
      authEmail="$OPTARG"
      ;;
    'k')
      authKey="$OPTARG"
      ;;
    'l')
      use_local_iface_address='yes'
      ;;
    'i')
      use_local_iface_address='yes'
      iface="$OPTARG"
      ;;
    ':')
      echo "No argument value for option $OPTARG"
      printf "%s\n" "$USAGE"
      exit 1
      ;;
    *)
      echo 'Unknown error while processing options'
      printf "%s\n" "$USAGE"
      exit 1
      ;;
  esac
done

# get ip address
myIP=''
if [ "$use_local_iface_address" == "yes" ]; then
  if which ip >/dev/null 2>&1; then
    myIP=$(ip addr show dev "$iface" | grep inet\ .*scope\ global | sed "$sed_ex_sw" 's/[^0-9]*([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})\/[0-9]{1,2}.*/\1/g')
  elif which ifconfig >/dev/null 2>&1; then
    myIP=$(ifconfig "$iface" inet | grep -E '^.*inet [0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}.*$' | sed "$sed_ex_sw" 's/^.*inet ([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}).*$/\1/')
  else
    logger -i -t com.bennettp123.mycfdns "${fqdn}: could not determine local IP address"
    exit 1
  fi
else
  myIP=$(curl --silent -4 -x "${http_proxy}" http://icanhazip.com/)
  if ! echo "${myIP}" | grep -qE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'; then
    logger -i -t com.bennettp123.mycfdns "${fqdn}: error fetching IP address"
    exit 1
  fi
fi

# Get zone info
zoneObject=$(curl --silent -X GET "https://api.cloudflare.com/client/v4/zones?name=${zone}&status=active" -H "Content-Type:application/json" -H "X-Auth-Email: ${authEmail}" -H "X-Auth-Key: ${authKey}")
success=$(echo "${zoneObject}" | python -c 'import json,sys;obj=json.load(sys.stdin);print obj["success"]')
errors=$(echo "${zoneObject}" | python -c 'import json,sys;obj=json.load(sys.stdin);print obj["errors"]')
count=$(echo "${zoneObject}" | python -c 'import json,sys;obj=json.load(sys.stdin);print obj["result_info"]["count"]')
if [ "${success}" != "True" ]; then
  logger -i -t com.bennettp123.mycfdns "${fqdn}: error fetching zone! ${errors}"
  exit 1
elif [ ${count} -le 0 ]; then
  logger -i -t com.bennettp123.mycfdns "${fqdn}: zone not found!"
  exit 1
elif [ ${count} -gt 1 ]; then
  logger -i -t com.bennettp123.mycfdns "${fqdn}: too many zones found!"
  exit 1
fi

zoneID=$(echo "${zoneObject}" | python -c 'import json,sys;obj=json.load(sys.stdin);print obj["result"][0]["id"]')

# get the current record
recordObject=$(curl --silent -X GET "https://api.cloudflare.com/client/v4/zones/${zoneID}/dns_records?type=A&name=${fqdn}" -H "Content-Type:application/json" -H "X-Auth-Email: ${authEmail}" -H "X-Auth-Key: ${authKey}")
success=$(echo "${recordObject}" | python -c 'import json,sys;obj=json.load(sys.stdin);print obj["success"]')
errors=$(echo "${recordObject}" | python -c 'import json,sys;obj=json.load(sys.stdin);print obj["errors"]')
messages=$(echo "${recordObject}" | python -c 'import json,sys;obj=json.load(sys.stdin);print obj["messages"]')
count=$(echo "${recordObject}" | python -c 'import json,sys;obj=json.load(sys.stdin);print obj["result_info"]["count"]')
if [ "${success}" != "True" ]; then
  logger -i -t com.bennettp123.mycfdns "${fqdn}: error fetching record! ${errors}"
  exit 1
fi
if [ ${count} -le 0 ]; then
  logger -i -t com.bennettp123.mycfdns "${fqdn}: record not found!"
  exit 1
elif [ ${count} -gt 1 ]; then
  logger -i -t com.bennettp123.mycfdns "${fqdn}: too many records found!"
  exit 1
fi

# quit unless the IP address has changed
currentIP=$(echo "${recordObject}" | python -c 'import json,sys;obj=json.load(sys.stdin);print obj["result"][0]["content"]')
if [ "${myIP}" = "${currentIP}" ]; then
  logger -i -t com.bennettp123.mycfdns "${fqdn}: ${currentIP} same as ${myIP}: exiting."
  exit 0
fi

# update the record
newRecordObject=$(echo "${recordObject}" | python -c 'import json,sys;obj=json.load(sys.stdin);obj["result"][0]["content"]="'"${myIP}"'";print json.dumps(obj["result"][0])')
recID=$(echo "${newRecordObject}" | python -c 'import json,sys;obj=json.load(sys.stdin);print obj["id"]')

resultObject=$(curl --silent -X PUT "https://api.cloudflare.com/client/v4/zones/${zoneID}/dns_records/${recID}" -H "Content-Type:application/json" -H "X-Auth-Email: ${authEmail}" -H "X-Auth-Key: ${authKey}" --data "${newRecordObject}")
success=$(echo "${resultObject}" | python -c 'import json,sys;obj=json.load(sys.stdin);print obj["success"]')
errors=$(echo "${resultObject}" | python -c 'import json,sys;obj=json.load(sys.stdin);print obj["errors"]')
messages=$(echo "${resultObject}" | python -c 'import json,sys;obj=json.load(sys.stdin);print obj["messages"]')
if [ "${success}" != "True" ]; then
  logger -i -t com.bennettp123.mycfdns "${fqdn}: error updating record! ${errors}"
  exit 1
fi

logger -i -t com.bennettp123.mycfdns "${fqdn}: ${currentIP} -> ${myIP}: success"
exit $retval
