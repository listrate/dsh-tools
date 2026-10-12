#!/bin/sh
# dsh-tools entrypoint — serve the DeepSeek Harness Web UI.
#
# Invoked with arguments, it execs them unchanged (e.g. `dsh --profile
# headless "..."` or an interactive shell). With no arguments it starts the
# `web` profile, streams its log, rewrites the tokenized startup URL to the
# public address the operator actually uses, and keeps the container alive
# exactly as long as the server is.
#
# Deployment-time configuration (all public values):
#   DSH_WORKSPACE   workspace root the harness launches from (default /workspace)
#   DSH_PUBLIC_URL  browser-facing root, e.g. https://agent.example.com (optional)
#   DSH_URL_FILE    where to persist the authenticated URL (default $HOME/.dsh-web-url)

set -eu

# An explicit command wins, so the image doubles as a general harness CLI.
if [ "$#" -gt 0 ]; then
  exec "$@"
fi

WORKSPACE="${DSH_WORKSPACE:-/workspace}"
PUBLIC_URL="${DSH_PUBLIC_URL:-}"
URL_FILE="${DSH_URL_FILE:-${HOME:-/root}/.dsh-web-url}"
LOG_FILE="${DSH_LOG_FILE:-/tmp/dsh-web.log}"

if [ ! -d "$WORKSPACE" ]; then
  echo "entrypoint: workspace '${WORKSPACE}' does not exist (set DSH_WORKSPACE)" >&2
  exit 1
fi
cd "$WORKSPACE"

# The launcher refuses a wildcard --host, so the bind address lives in the
# profile patch (host: 0.0.0.0); the token line is the only way to obtain the
# per-process launch token, hence the stdout capture below.
: > "$LOG_FILE"
dsh web --no-open > "$LOG_FILE" 2>&1 &
DSH_PID=$!

echo "entrypoint: dsh web started (pid ${DSH_PID}, workspace ${WORKSPACE})" >&2

trap 'kill "$DSH_PID" 2>/dev/null || true' INT TERM

# Rewrite the startup URL and persist it. The harness prints the loopback URL;
# behind a reverse proxy the operator needs the public one, with the token.
tail -n +1 -F "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
  case "$line" in
    "dsh web: "*)
      TOKEN="$(printf '%s\n' "$line" | sed -n 's/.*[?&]token=\([A-Za-z0-9_-]*\).*/\1/p' | head -n 1)"
      if [ -n "$PUBLIC_URL" ] && [ -n "$TOKEN" ]; then
        URL="${PUBLIC_URL%/}/?token=${TOKEN}"
        printf 'dsh web: %s\n' "$URL"
        ( umask 077; printf '%s\n' "$URL" > "$URL_FILE" )
        echo "entrypoint: authenticated URL written to ${URL_FILE}" >&2
      else
        printf '%s\n' "$line"
        if [ -n "$TOKEN" ]; then
          ( umask 077; printf '%s\n' "$line" > "$URL_FILE" )
        fi
      fi
      ;;
    *)
      printf '%s\n' "$line"
      ;;
  esac
done &
TAIL_PID=$!

# Exit as soon as the server dies so Kubernetes restarts the container.
while :; do
  if ! kill -0 "$DSH_PID" 2>/dev/null; then
    echo "entrypoint: dsh web exited (pid ${DSH_PID})" >&2
    kill "$TAIL_PID" 2>/dev/null || true
    wait "$DSH_PID" || exit 1
    exit 1
  fi
  sleep 2
done
