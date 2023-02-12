[ -d /data/scripts ] || mkdir -p /data/scripts
[ -d /data/templates ] || mkdir -p /data/templates
project_base="https://raw.githubusercontent.com/xdancho/fly-matrix/main"
curl -o /data/scripts/generate-config.sh -s "${synapse_scripts}/scripts/synapse/generate-config.sh"
curl -o /data/templates/homeserver.yaml -s "${synapse_scripts}/templates/homeserver.yaml"
chmod +x /data/scripts/generate-config.sh