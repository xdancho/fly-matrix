[ -d /data/scripts ] || mkdir -p /data/scripts
[ -d /data/templates ] || mkdir -p /data/templates
project_base="https://raw.githubusercontent.com/xdancho/fly-matrix/main"
curl -o /data/scripts/generate-config.sh -s "${project_base}/scripts/synapse/generate-config.sh"
curl -o /data/scripts/start.py -s "${project_base}/scripts/synapse/start.py"
curl -o /data/templates/homeserver.yaml -s "${project_base}/templates/homeserver.yaml"
chmod +x /data/scripts/generate-config.sh /data/scripts/start.py