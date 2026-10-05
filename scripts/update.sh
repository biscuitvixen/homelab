#!/bin/bash

# Navigate to the project directory
cd "$(dirname "$0")/.." || exit 1

# Compose reads COMPOSE_PROFILES from .env. Without it every service is
# filtered out and `up -d` silently does nothing.
if ! grep -q '^COMPOSE_PROFILES=' .env 2>/dev/null && [ -z "$COMPOSE_PROFILES" ]; then
    echo "COMPOSE_PROFILES is not set in .env (serv or replica); refusing to run" >&2
    exit 1
fi

# Pull the latest images for all services
docker compose pull

# Restart all services to apply updates
docker compose up -d

# Optionally, remove unused images
docker image prune -f

echo "Services updated successfully."
