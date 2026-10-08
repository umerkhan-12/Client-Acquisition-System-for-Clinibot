#!/bin/sh
# First boot on an empty Railway volume: restore the snapshot taken from the
# local n8n, so the owner account, credentials, published workflows and their
# IDs (errorWorkflow is referenced by ID) arrive intact. Never overwrites an
# existing database: after the first boot the volume is the source of truth.
set -eu
dir="${N8N_USER_FOLDER:-/data}/.n8n"
mkdir -p "$dir"
if [ ! -s "$dir/database.sqlite" ] && [ -s /opt/seed/database.sqlite ]; then
  echo "railway-entrypoint: empty volume, restoring n8n state from the seed snapshot"
  cp /opt/seed/database.sqlite "$dir/database.sqlite"
  chmod 600 "$dir/database.sqlite"
fi
exec /docker-entrypoint.sh "$@"
