[ -d /data/scripts ] || mkdir -p /data/scripts
synapse_scripts="https://raw.githubusercontent.com/xdancho/fly-matrix/main/scripts/synapse"
curl -o /data/scripts/generate-config.sh -s "${synapse_scripts}/generate-config.sh"
chmod +x /data/scripts/generate-config.sh
