#!/bin/bash
if test -f /data/homeserver.yaml; then
    echo "Synapse homeserver config already exists"
    exit 0
fi
/data/scripts/synapse/start.py generate
/data/scripts/synapse/start.py migrate_config
