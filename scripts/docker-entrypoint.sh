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

# Sync the agent-config repo onto the volume so Paperclip agents can
# point at /paperclip/repos/immigro-news-alerts/paperclip-config/<role>
# as their working directory. Idempotent: clones on first run, pulls on
# every subsequent restart. Public repo, no auth needed for clone+pull.
# Configurable via env var so other forks can point at their own repo.
AGENT_CONFIG_REPO=${AGENT_CONFIG_REPO:-https://github.com/Kintupercy/immigro-news-alerts.git}
AGENT_CONFIG_DIR=${AGENT_CONFIG_DIR:-/paperclip/repos/immigro-news-alerts}
if [ -n "$AGENT_CONFIG_REPO" ]; then
    mkdir -p "$(dirname "$AGENT_CONFIG_DIR")"
    chown -R node:node "$(dirname "$AGENT_CONFIG_DIR")"
    if [ ! -d "$AGENT_CONFIG_DIR/.git" ]; then
        echo "Cloning agent config repo: $AGENT_CONFIG_REPO -> $AGENT_CONFIG_DIR"
        gosu node git clone --depth 50 "$AGENT_CONFIG_REPO" "$AGENT_CONFIG_DIR" || \
            echo "WARN: agent config clone failed (continuing — Paperclip starts regardless)"
    else
        echo "Refreshing agent config repo at $AGENT_CONFIG_DIR"
        cd "$AGENT_CONFIG_DIR" && gosu node git pull --ff-only origin main || \
            echo "WARN: agent config pull failed (continuing — Paperclip starts regardless)"
    fi
fi

# Initialize the Paperclip instance + bootstrap the first admin if not done.
# Two-step: `paperclipai onboard --yes` writes the instance config, then
# `auth bootstrap-ceo` prints the magic invite URL. Both happen on first
# boot only — subsequent restarts skip via marker file.
ADMIN_BOOTSTRAP_MARKER="/paperclip/instances/default/.admin_bootstrap_done"
PAPERCLIP_CONFIG_FILE="/paperclip/instances/default/config.json"
if [ ! -f "$ADMIN_BOOTSTRAP_MARKER" ]; then
    echo "================================================================="
    echo "Paperclip first-run setup"
    echo "================================================================="
    if [ -d /app ]; then
        cd /app
        if [ ! -f "$PAPERCLIP_CONFIG_FILE" ]; then
            echo "Step 1/2: paperclipai onboard --yes"
            gosu node pnpm paperclipai onboard --yes 2>&1 || \
                echo "WARN: onboard failed"
        else
            echo "Step 1/2: instance config already present, skipping onboard"
        fi
        echo "Step 2/2: paperclipai auth bootstrap-ceo"
        gosu node pnpm paperclipai auth bootstrap-ceo 2>&1 || \
            echo "WARN: bootstrap-ceo failed"
        gosu node mkdir -p "$(dirname "$ADMIN_BOOTSTRAP_MARKER")" 2>/dev/null || true
        gosu node touch "$ADMIN_BOOTSTRAP_MARKER" 2>/dev/null || true
    else
        echo "WARN: /app directory missing; cannot run bootstrap"
    fi
    echo "================================================================="
fi

exec gosu node "$@"
