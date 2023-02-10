[ -d /data/scripts ] || mkdir -p /data/scripts
pgsql_scripts="https://raw.githubusercontent.com/xdancho/fly-matrix/main/scripts/pgsql"
curl -o /data/scripts/create-userdb.sh -s "${pgsql_scripts}/create-userdb.sh"
chmod +x /data/scripts/create-userdb.sh
