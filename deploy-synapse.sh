#!/bin/bash
domain="$1"   # domain name, should be tld
user_id="$2"  # user id from a db
ded_ip="$3"   # we can use shared ips for testing

project_home="https://raw.githubusercontent.com/xdancho/fly-matrix/main"

if [ -z $domain ] || [ -z "$user_id" ]; then
	echo "Usage: $0 [DOMAIN] [USER_ID]"
	exit 1
fi

# env vars
if [ -z "$REGION" ]; then
	REGION="dfw"
else
	if ! fly platform regions |grep -wq "$REGION"; then
		echo "ERROR: Invalid region: $REGION"
		exit 1
	fi
fi

if [ -z "$CPU_SIZE" ]; then
	CPU_SIZE="shared-cpu-1x"
else
	if ! fly platform vm-sizes |grep -wq "$CPU_SIZE"; then
		echo "ERROR: Invalid cpu size: $CPU_SIZE"
		exit 1
	fi
fi

if [ -z "$DISK_SIZE" ]; then
	DISK_SIZE="1"
else
	if ! echo "$DISK_SIZE" |grep -q '^[0-9]\+$'; then
		echo "ERROR: Invalid disk size: $DISK_SIZE"
		exit 1
	fi
fi

if echo "$user" |grep -q ^u; then
	user=$(echo "$user" |sed 's/^u//')
fi

USER_APP="u${user_id}-app"
DB_APP="u${user_id}-db"

for i in $USER_APP $DB_APP; do
	if fly apps list |grep -qw "$i"; then
		echo "APP: ${i} already exist"
		exit 1
	fi
done

############################
# postgres cluster app
############################
pgsql_update_script="${project_home}/scripts/pgsql/update-scripts.sh"

fly postgres create --machines -r "$REGION" -n "$DB_APP" \
	--initial-cluster-size 1 --vm-size "$CPU_SIZE" \
	--volume-size "$DISK_SIZE" -o personal

pri_machine_id=""
# wait for the machine id to be available, flyio is kinda slow
sleep 5
attempt=0
while true; do
	attempt=$((attempt+1))
	echo "Attempting to fetch machine ID ..."
	pri_machine_id=$(fly machines list --app "$DB_APP" -q -j 2>/dev/null| jq -r '.[0].id' 2>/dev/null)
	[ -z "$pri_machine_id" ] || break
	if [ "$attempt" -gt 5 ]; then
		echo "ERROR failed to get ${DB_APP} machine_id, "
		echo "check: fly machines list --app ${DB_APP}"
		exit 1
	fi
	echo "Failed to obtain machine id, retrying in 5 seconds"
	sleep 5
done

echo "Deploying scripts in persistent volume"
curl_cmd="curl -o /data/update-scripts.sh -s $pgsql_update_script"
fly machine exec "$pri_machine_id" "$curl_cmd" --app "$DB_APP"
fly machine exec "$pri_machine_id" "/bin/bash /data/update-scripts.sh" --app "$DB_APP"

echo "Creating secondary postgres instance"
if ! fly machine clone "$pri_machine_id" --region "$REGION" --app "$DB_APP"; then
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
	sec_machine_id=$(fly machines list --app "$DB_APP" -q -j |jq -r '.[].id' |grep -v "$pri_machine_id")
	[ -z "$sec_machine_id" ] || break
	if [ "$attempt" -gt 5 ]; then
		echo "ERROR failed to get ${app} machine_id, "
		echo "check: fly machines list --app ${DB_APP}"
		exit 1
	fi
	echo "Failed to obtain machine id, retrying in 5 seconds"
	sleep 5
done

echo "Deploying scripts in persistent volume"
fly machine exec "$sec_machine_id" "$curl_cmd" --app "$DB_APP"
fly machine exec "$sec_machine_id" "/bin/bash /data/update-scripts.sh" --app "$DB_APP"


###########################
# synapse app
############################

echo "Creating user app: ${USER_APP}"
fly apps create --machines --name "$USER_APP" -o personal

echo "Creating new volume for ${app} with size: ${DISK_SIZE}GB"
fly volumes create --app "$USER_APP" -s "${DISK_SIZE}" userdata -r "$REGION"

echo "Creating pgsql db and user"

pgpass=$(openssl rand -hex 12)
echo "Creating new pgsql user for ${USER_APP}"
leader_id=$(fly status --app "$DB_APP" |grep -E '\s+leader\s+' | awk '{print $1}')
if [ -z "$leader_id" ]; then
	echo "ERROR failed to find pgsql leader machine ID"
	echo "check: fly status --app ${DB_APP}"
	exit 1
fi
echo Leader ID: $leader_id
# machine exec works only with single command + up to 1 argument
# anything else will fail, e.g. 'chmod +x file' will fail.
create_cmd="/data/scripts/create-userdb.sh synapse:${pgpass}"
if fly machines exec $leader_id "$create_cmd" |grep PG_FAILED; then
	echo "ERROR failed to create pgsql user for ${USER_APP}"
	echo "check: fly machines exec ${leader_id} '${create_cmd}'"
	exit 1
fi

echo "Creating new proxy IP address for ${USER_APP}"
iptype=""
if [ -z "$ded_ip" ]; then
	iptype="--shared"
fi
fly ips allocate-v4 $iptype --app "$USER_APP"

vmimage="matrixdotorg/synapse"
vmnt="userdata:/data"
vm_ports="-p 80:8008/tcp:http -p 443:8008/tcp:tls:http -p 443:8008/tcp:tls:http"
env="-e GID=0 -e UID=0 -e SYNAPSE_REPORT_STATS=no -e SYNAPSE_SERVER_NAME=${domain} -e SYNAPSE_NO_TLS=1"
env="${env} -e POSTGRES_USER=synapse -e POSTGRES_DB=synapse -e POSTGRES_HOST=${DB_APP}.internal -e POSTGRES_PORT=5432 -e POSTGRES_PASSWORD=${pgpass}"
echo "Starting the synapse container"
flyctl machine run "$vmimage" -v "$vmnt" -r "$REGION" -n "$USER_APP" --app "$USER_APP" --size "$CPU_SIZE" $vm_ports $env --entrypoint "sleep 120"

# flyio api is kinda slow, so we need to wait a bit
sleep 5
attempt=0
while true; do
	attempt=$((attempt+1))
	echo "Attempting to fetch machine ID ..."
	machine_id=$(fly machines list --app "$USER_APP" -q -j 2>/dev/null| jq -r '.[0].id' 2>/dev/null)
	[ -z "$machine_id" ] || break
	if [ $attempt -gt 5 ]; then
		echo "ERROR failed to get ${USER_APP} machine_id, "
		echo "check: fly machines list --app ${USER_APP}"
		exit 1
	fi
	echo "Failed to obtain machine id, retrying in 5 seconds"
	sleep 5
done

echo "Deploying scripts in persistent volume"
curl_cmd="curl -o /data/update-scripts.sh -s ${project_home}/scripts/synapse/update-scripts.sh"
fly machine exec "$machine_id" "$curl_cmd" --app "$USER_APP"
fly machine exec "$machine_id" "/bin/bash /data/update-scripts.sh" --app "$USER_APP"
echo "Running synapse config generator"
fly machine exec "$machine_id" "/data/scripts/generate-config.sh" --app "$USER_APP"
echo "Stopping the container"
fly machine stop "$machine_id" --app "$USER_APP"
echo "Updating the entrypoint and running the container"
flyctl machine update "$machine_id" --app "$USER_APP" --entrypoint "/start.py" -y