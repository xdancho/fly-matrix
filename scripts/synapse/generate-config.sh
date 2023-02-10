#!/bin/bash
if test -f /data/homeserver.yaml; then
    echo "Synapse homeserver config already exists"
    exit 0
fi
/start.py generate
/start.py migrate_config
