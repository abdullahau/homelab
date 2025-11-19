#!/usr/bin/env zsh

COMPOSE_FILES=(*-docker-compose.yml)

case "$1" in
    up)
        for file in "${COMPOSE_FILES[@]}"; do
            echo "Starting $file..."
            docker compose -f "$file" up -d
        done
        ;;
    down)
        for file in "${COMPOSE_FILES[@]}"; do
            echo "Stopping $file..."
            docker compose -f "$file" down
        done
        ;;
    pull)
        for file in "${COMPOSE_FILES[@]}"; do
            echo "Pulling latest images for $file..."
            docker compose -f "$file" pull
        done
        ;;
    update)
        echo "Pulling latest images..."
        for file in "${COMPOSE_FILES[@]}"; do
            echo "Pulling $file..."
            docker compose -f "$file" pull
        done
        echo "Restarting services..."
        for file in "${COMPOSE_FILES[@]}"; do
            echo "Restarting $file..."
            docker compose -f "$file" up -d
        done
        ;;
    restart)
        $0 down
        $0 up
        ;;
    status)
        for file in "${COMPOSE_FILES[@]}"; do
            echo "=== $file ==="
            docker compose -f "$file" ps
        done
        ;;
    *)
        echo "Usage: $0 {up|down|pull|update|restart|status}"
        exit 1
        ;;
esac
