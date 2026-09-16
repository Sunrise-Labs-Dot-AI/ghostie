#!/bin/sh
set -eu
umask 077
ulimit -c 0
# The only writable persistent path is this service's metadata volume.
mkdir -p /data
chown bun:bun /data
chmod 700 /data
exec su-exec bun:bun bun run /app/src/supervisor.ts
