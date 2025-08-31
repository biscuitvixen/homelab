#!/bin/bash

# Navigate to the project directory
cd "$(dirname "$0")/.."

# Pull the latest images for all services
docker-compose pull

# Restart all services to apply updates
docker-compose up -d

# Optionally, remove unused images
docker image prune -f

echo "Services updated successfully."