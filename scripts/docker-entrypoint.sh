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
#
# Tricky sequencing: `paperclipai onboard --yes` writes the instance config
# AND auto-starts the server (it's quickstart-equivalent). With embedded-pg
# (our mode), onboard does NOT print the bootstrap invite inline — that
# only happens when database is external Postgres. So we must run
# `auth bootstrap-ceo` AFTER the embedded-pg server is up.
#
# Solution: spawn a background process that polls the local server health
# endpoint, then runs `auth bootstrap-ceo` against the running embedded-pg.
# The invite URL prints to deploy logs. Marker is touched only on success
# so failures self-heal on next boot. Skip the whole thing only when both
# config AND marker exist.
# Marker is versioned to invalidate stale ones on existing volumes when
# the bootstrap behavior changes. v1 = pre-cwd-fix; v2 = had the bug
# where local_trusted-mode bootstrap-ceo returned success without doing
# anything (so the marker got touched even though no admin was created);
# v3 = current logic, which patches config to authenticated mode first.
ADMIN_BOOTSTRAP_MARKER="/paperclip/instances/default/.admin_bootstrap_done.v3"
PAPERCLIP_CONFIG_FILE="/paperclip/instances/default/config.json"

# Drop stale legacy markers idempotently (no volume access needed).
for legacy in \
    /paperclip/instances/default/.admin_bootstrap_done \
    /paperclip/instances/default/.admin_bootstrap_done.v2; do
    [ -f "$legacy" ] && rm -f "$legacy" 2>/dev/null || true
done

# Sync config.json with what we actually want at runtime, on every boot.
# `paperclipai onboard --yes` hardcodes loopback/local_trusted defaults
# and explicitly ignores PAPERCLIP_DEPLOYMENT_MODE / HOST env vars, so
# the saved config is wrong on three counts for our setup:
#   1. deploymentMode = "local_trusted"  (we want "authenticated" so the
#      bootstrap-ceo CLI doesn't short-circuit and so the running server
#      enforces auth on incoming requests via the Cloudflare tunnel)
#   2. bind = "loopback" / host = "127.0.0.1" (we want "lan" / "0.0.0.0"
#      so the cloudflared sidecar in the sibling Railway service can
#      reach paperclip — loopback is per-container, sidecars cannot reach
#      it; this was the root cause of the post-bootstrap 502s)
#   3. (auth.publicBaseUrl / trustedOrigins are populated from env vars
#      at runtime, so no patch needed there)
#
# Idempotent: only rewrites when at least one of the three target fields
# is wrong. Runs as root (no gosu) because /usr/bin/jq is not on the node
# user's default PATH after gosu's env scrub; root can read/write the
# file regardless of ownership, and we chown back to node afterward.
if [ -f "$PAPERCLIP_CONFIG_FILE" ]; then
    cur_mode=$(jq -r '.server.deploymentMode // empty' "$PAPERCLIP_CONFIG_FILE" 2>/dev/null || true)
    cur_bind=$(jq -r '.server.bind // empty' "$PAPERCLIP_CONFIG_FILE" 2>/dev/null || true)
    cur_host=$(jq -r '.server.host // empty' "$PAPERCLIP_CONFIG_FILE" 2>/dev/null || true)
    if [ "$cur_mode" != "authenticated" ] || [ "$cur_bind" != "lan" ] || [ "$cur_host" != "0.0.0.0" ]; then
        echo "Patching config.json: deploymentMode=authenticated, bind=lan, host=0.0.0.0 (was: $cur_mode/$cur_bind/$cur_host)"
        tmp_cfg=$(mktemp)
        tmp_err=$(mktemp)
        if jq '.server.deploymentMode = "authenticated" | .server.bind = "lan" | .server.host = "0.0.0.0" | .server.customBindHost = null' \
            "$PAPERCLIP_CONFIG_FILE" >"$tmp_cfg" 2>"$tmp_err"; then
            if [ -s "$tmp_cfg" ] && head -c1 "$tmp_cfg" | grep -q '{'; then
                mv "$tmp_cfg" "$PAPERCLIP_CONFIG_FILE"
                chown node:node "$PAPERCLIP_CONFIG_FILE" 2>/dev/null || true
                chmod 0644 "$PAPERCLIP_CONFIG_FILE" 2>/dev/null || true
                echo "Config patched successfully"
            else
                rm -f "$tmp_cfg"
                echo "WARN: jq output looked invalid; aborting patch"
            fi
        else
            jq_err=$(cat "$tmp_err" 2>/dev/null || echo "<no stderr>")
            rm -f "$tmp_cfg"
            echo "WARN: jq exit nonzero. stderr: $jq_err"
        fi
        rm -f "$tmp_err"
    fi
fi

if [ ! -f "$ADMIN_BOOTSTRAP_MARKER" ] && [ -d /app ]; then
    (
        # Wait up to ~3 minutes for the paperclip server's health endpoint.
        # 8080 is bound by `paperclipai run` after embedded-pg is up and
        # migrations have applied — that's exactly when bootstrap-ceo can
        # safely query the DB.
        for i in $(seq 1 90); do
            sleep 2
            if curl -fsS -m 2 http://127.0.0.1:8080/api/health >/dev/null 2>&1; then
                break
            fi
        done
        # Small grace period for migrations to finish post-listen.
        sleep 3
        cd /app

        echo "================================================================="
        echo "Paperclip background bootstrap: paperclipai auth bootstrap-ceo"
        echo "================================================================="
        # Capture output so we can verify an invite was actually printed —
        # the CLI exits 0 even on no-op short-circuits, so exit code alone
        # is not a reliable success signal.
        bootstrap_log=$(gosu node pnpm paperclipai auth bootstrap-ceo 2>&1 || true)
        printf '%s\n' "$bootstrap_log"
        if printf '%s' "$bootstrap_log" | grep -q '/invite/pcp_bootstrap_'; then
            gosu node mkdir -p "$(dirname "$ADMIN_BOOTSTRAP_MARKER")" 2>/dev/null || true
            gosu node touch "$ADMIN_BOOTSTRAP_MARKER" 2>/dev/null || true
            echo "Bootstrap marker set; this will not run again on subsequent boots."
        else
            echo "WARN: bootstrap-ceo did not produce an invite URL; leaving marker absent so next boot retries"
        fi
        echo "================================================================="
    ) &
fi

# Paperclip's CMD uses relative paths (./server/node_modules/tsx/...,
# server/dist/index.js) so cwd MUST be /app at exec time. The agent-config
# git pull above cd's into the immigro repo, so restore /app here.
cd /app 2>/dev/null || true

# First boot: config doesn't exist yet, so we must run onboard to write it.
# Onboard --yes auto-starts the server (the same server the CMD would
# launch), so this becomes the foreground process. Subsequent boots have
# config present and skip straight to the CMD.
if [ ! -f "$PAPERCLIP_CONFIG_FILE" ]; then
    echo "First boot detected (no config). Running paperclipai onboard --yes."
    exec gosu node pnpm paperclipai onboard --yes
fi

exec gosu node "$@"
