#!/usr/bin/env bash
# Renders config.yaml.template -> config.yaml using values from .env.
# Hysteria does NOT expand ${VAR} in its config, so substitution happens here.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] || { echo "missing .env (copy .env.example)" >&2; exit 1; }
set -a; . ./.env; set +a
: "${HYSTERIA_PASSWORD:?HYSTERIA_PASSWORD not set in .env}"
envsubst '${HYSTERIA_PASSWORD}' < config.yaml.template > config.yaml
chmod 600 config.yaml
echo "rendered config.yaml"
