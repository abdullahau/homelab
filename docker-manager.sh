#!/usr/bin/env zsh
# Drives every top-level *-docker-compose.yml.
#
# The glob is deliberately NOT recursive: hysteria/hysteria-docker-compose.yml
# runs on the Oracle VPS, not on this host, and must never start here.
set -euo pipefail

cd "${0:a:h}"

COMPOSE_FILES=(*-docker-compose.yml(N))
(( ${#COMPOSE_FILES} )) || { echo "no compose files found" >&2; exit 1; }

failed=()

run_all() {
    local action=$1; shift
    for file in $COMPOSE_FILES; do
        echo "==> $action $file"
        if ! docker compose -f "$file" "$@"; then
            failed+=("$file")
            echo "!!! FAILED: $file" >&2
        fi
    done
}

report() {
    if (( ${#failed} )); then
        echo >&2
        echo "${#failed} file(s) failed:" >&2
        printf '  %s\n' $failed >&2
        exit 1
    fi
    echo
    echo "OK: ${#COMPOSE_FILES} file(s)"
}

case "${1:-}" in
    up)      run_all Starting up -d ;;
    down)    run_all Stopping down ;;
    pull)    run_all Pulling pull ;;
    logs)    run_all Logs logs --tail 50 ;;
    status)  run_all Status ps ;;
    update)  run_all Pulling pull; run_all Restarting up -d ;;
    restart) run_all Stopping down; run_all Starting up -d ;;
    render)  ./scripts/render.sh; exit $? ;;
    *)
        echo "Usage: $0 {up|down|pull|update|restart|status|logs|render}"
        exit 1
        ;;
esac

report
