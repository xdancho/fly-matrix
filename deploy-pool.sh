#!/bin/bash
pool="$1"
project_home="https://raw.githubusercontent.com/xdancho/fly-matrix/main"
update_script_url="${project_home}/scripts/pgsql/update-scripts.sh"

if [ -z "$pool" ]; then
	echo "Usage: $0 [POOL_NAME]"
	exit 1
fi

if [ -z "$PGSQL_REGION" ]; then
	VM_REGION="dfw"
else
	if ! fly platform regions |grep -wq "$PGSQL_REGION"; then
		echo "ERROR: Invalid region: $PGSQL_REGION"
		exit 1
	fi
	VM_REGION="$PGSQL_REGION"
fi

if [ -z "$PGSQL_CPU_SIZE" ]; then
	VM_CPU_SIZE="shared-cpu-1x"
else
	if ! fly platform vm-sizes |grep -wq "$PGSQL_CPU_SIZE"; then
		echo "ERROR: Invalid cpu size: $PGSQL_CPU_SIZE"
		exit 1
	fi
	VM_CPU_SIZE="$PGSQL_CPU_SIZE"
fi

if [ -z "$PGSQL_DISK_SIZE" ]; then
	VM_DISK_SIZE="1"
else
	if ! echo "$PGSQL_DISK_SIZE" |grep -q '^[0-9]\+$'; then
		echo "ERROR: Invalid disk size: $PGSQL_DISK_SIZE"
		exit 1
	fi
	VM_DISK_SIZE="$PGSQL_DISK_SIZE"
fi

if echo "$pool" |grep -q ^pool; then
	pool=$(echo "$pool" |sed 's/^pool//')
fi

pool="pool${pool}"
app="${pool}-db"

echo "Checking if the pool app exist"
if fly apps list |grep -wq "$app"; then
	echo "${app} already exist"
	exit 1
fi

fly postgres create --machines -r "$VM_REGION" -n "$app" \
	--initial-cluster-size 1 --vm-size "$VM_CPU_SIZE" \
	--volume-size "$VM_DISK_SIZE" -o personal


pri_machine_id=""
# wait for the machine id to be available, flyio is kinda slow
sleep 5
attempt=0
while true; do
	attempt=$((attempt+1))
	echo "Attempting to fetch machine ID ..."
	pri_machine_id=$(fly machines list --app "$app" -q -j 2>/dev/null| jq -r '.[0].id' 2>/dev/null)
	[ -z "$pri_machine_id" ] || break
	if [ "$attempt" -gt 5 ]; then
		echo "ERROR failed to get ${app} machine_id, "
		echo "check: fly machines list --app ${app}"
		exit 1
	fi
	echo "Failed to obtain machine id, retrying in 5 seconds"
	sleep 5
done

echo "Deploying scripts in persistent volume"
curl_cmd="curl -o /data/update-scripts.sh -s $update_script_url"
fly machine exec "$pri_machine_id" "$curl_cmd" --app "$app"
fly machine exec "$pri_machine_id" "/bin/bash /data/update-scripts.sh" --app "$app"

echo "Creating secondary postgres instance"
if ! fly machine clone "$pri_machine_id" --region "$VM_REGION" --app "$app"; then
	echo "ERROR failed to clone pgsql machine"
	exit 1
fi

sec_machine_id=""
# again wait for the machine id to be available
sleep 5
attempt=0
while true; do
	attempt=$((attempt+1))
	echo "Attempting to fetch machine ID ..."
	sec_machine_id=$(fly machines list --app "$app" -q -j |jq -r '.[].id' |grep -v "$pri_machine_id")
	[ -z "$sec_machine_id" ] || break
	if [ "$attempt" -gt 5 ]; then
		echo "ERROR failed to get ${app} machine_id, "
		echo "check: fly machines list --app ${app}"
		exit 1
	fi
	echo "Failed to obtain machine id, retrying in 5 seconds"
	sleep 5
done

echo "Deploying scripts in persistent volume"
fly machine exec "$sec_machine_id" "$curl_cmd" --app "$app"
fly machine exec "$sec_machine_id" "/bin/bash /data/update-scripts.sh" --app "$app"