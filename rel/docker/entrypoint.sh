#!/bin/sh
# Docker entrypoint: runs pending migrations, then the release command
# (`start` by default). Any other command (`remote`, `eval ...`) is passed
# straight to the release script. RUN_MIGRATIONS=false skips the migrations.
set -e

if [ "$1" = "start" ] && [ "${RUN_MIGRATIONS:-true}" = "true" ]; then
  /app/bin/retrieval_node eval "RetrievalNode.Release.migrate()"
fi

exec /app/bin/retrieval_node "$@"
