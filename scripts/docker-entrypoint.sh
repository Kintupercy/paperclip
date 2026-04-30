#!/bin/sh
set -e

# Capture runtime UID/GID from environment variables, defaulting to 1000
PUID=${USER_UID:-1000}
PGID=${USER_GID:-1000}

# Adjust the node user's UID/GID if they differ from the runtime request
# and fix volume ownership only when a remap is needed
changed=0

if [ "$(id -u node)" -ne "$PUID" ]; then
    echo "Updating node UID to $PUID"
    usermod -o -u "$PUID" node
    changed=1
fi

if [ "$(id -g node)" -ne "$PGID" ]; then
    echo "Updating node GID to $PGID"
    groupmod -o -g "$PGID" node
    usermod -g "$PGID" node
    changed=1
fi

if [ "$changed" = "1" ]; then
    chown -R node:node /paperclip
fi

# Always ensure the node user owns the volume root. Container platforms
# like Railway mount volumes owned by root over the Dockerfile's chown,
# so even with no UID/GID remap the volume root may be unwritable.
# Touching ownership of just the top-level dir is fast (no recurse) and
# only needed once — Paperclip's own writes from there will be node-owned.
if [ "$(stat -c '%u:%g' /paperclip)" != "$(id -u node):$(id -g node)" ]; then
    echo "Fixing /paperclip ownership for node user"
    chown node:node /paperclip
fi

exec gosu node "$@"
