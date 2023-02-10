#!/bin/bash
pool="$1"     # pool name e.g. pool240
domain="$2"   # domain name, should be tld
user="$3"     # user id from a db
ded_ip="$4"   # we can use shared ips for testing
region="dfw"
data_size="1"

if [ -z "$pool" ] || [ -z $domain ] || [ -z "$user" ]; then
	echo "Usage: $0 [POOL_NAME] [DOMAIN] [USER_ID]"
	exit 1
fi

# env vars
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



if echo "$user" |grep -q ^u; then
	user=$(echo "$user" |sed 's/^u//')
fi
echo "Checking the pool"
if ! fly apps list |grep -q "^${pool}-db"; then
	echo "${pool} not found"
	exit 1
fi

app="${pool}u${user}"

echo "Checking user app: ${app}"
if fly apps list |grep -q "^${app}"; then
	echo "${app} already exist"
	exit 1
fi

echo "Creating app ${app}"
fly apps create --machines --name "$app" -o personal

echo "Creating new volume for ${app} with size: ${VM_DISK_SIZE}GB"
fly volumes create --app "$app" -s "${VM_DISK_SIZE}" userdata -r "$VM_REGION"

dbapp="${pool}-db"
echo "Creating pgsql db and user"

pgpass=$(openssl rand -hex 12)
echo "Creating new pgsql user for ${app}"
leader_id=$(fly status --app "$dbapp" |grep -E '\s+leader\s+' | awk '{print $1}')
if [ -z "$leader_id" ]; then
	echo "ERROR failed to find pgsql leader machine ID"
	echo "check: fly status --app ${dbapp}"
	exit 1
fi
echo Leader ID: $leader_id
# machine exec works only with single command + up to 1 argument
# anything else will fail, e.g. 'chmod +x file' will fail.
create_cmd="/data/scripts/create-userdb.sh ${app}:${pgpass}"
if fly machines exec $leader_id "$create_cmd" |grep PG_FAILED; then
	echo "ERROR failed to create pgsql user for ${app}"
	echo "check: fly machines exec ${leader_id} '${create_cmd}'"
	exit 1
fi

echo "Creating new proxy IP address for ${app}"
iptype=""
if [ -z "$ded_ip" ]; then
	iptype="--shared"
fi
fly ips allocate-v4 $iptype --app "$app"

vmimage="matrixdotorg/synapse"
vmnt="userdata:/data"
vm_ports="-p 80:8008/tcp:http -p 443:8008/tcp:tls:http -p 443:8008/tcp:tls:http"
env="-e GID=0 -e UID=0 -e SYNAPSE_REPORT_STATS=no -e SYNAPSE_SERVER_NAME=${domain} -e SYNAPSE_NO_TLS=1"
env="${env} -e POSTGRES_USER=${app} -e POSTGRES_DB=${app} -e POSTGRES_HOST=${dbapp}.internal -e POSTGRES_PORT=5432 -e POSTGRES_PASSWORD=${pgpass}"
echo "Starting the synapse container"
flyctl machine run "$vmimage" -v "$vmnt" -r "$VM_REGION" -n "$app" --app "$app" --size "$VM_CPU_SIZE" $vm_ports $env --entrypoint "sleep 120"

# flyio api is kinda slow, so we need to wait a bit
sleep 5
attempt=0
while true; do
	attempt=$((attempt+1))
	echo "Attempting to fetch machine ID ..."
	machine_id=$(fly machines list --app "$app" -q -j 2>/dev/null| jq -r '.[0].id' 2>/dev/null)
	[ -z "$machine_id" ] || break
	if [ $attempt -gt 5 ]; then
		echo "ERROR failed to get ${app} machine_id, "
		echo "check: fly machines list --app ${app}"
		exit 1
	fi
	echo "Failed to obtain machine id, retrying in 5 seconds"
	sleep 5
done

echo "Deploying scripts in persistent volume"
project_home="https://raw.githubusercontent.com/xdancho/fly-matrix/main"
update_script_url="${project_home}/scripts/synapse/update-scripts.sh"
curl_cmd="curl -o /data/update-scripts.sh -s $update_script_url"
fly machine exec "$machine_id" "$curl_cmd" --app "$app"
fly machine exec "$machine_id" "/bin/bash /data/update-scripts.sh" --app "$app"
echo "Running synapse config generator"
fly machine exec "$machine_id" "/data/scripts/generate-config.sh" --app "$app"
echo "Stopping the container"
fly machine stop "$machine_id" --app "$app"
echo "Updating the entrypoint and running the container"
flyctl machine update "$machine_id" --app "$app" --entrypoint "/start.py" -y