#!/bin/bash

# Restore script for Asteria Home Server

# Load environment variables
if [ -f ../.env ]; then
    export $(cat ../.env | xargs)
fi

# Load secrets
if [ -f ../secrets.env ]; then
    export $(cat ../secrets.env | xargs)
fi

# Define backup directory
BACKUP_DIR="/path/to/backup"  # Change this to your backup directory
DATA_DIR="../data"
CONFIG_DIR="../config"

# Restore data
echo "Restoring data from backup..."

for service in adguard homeassistant mosquitto caddy portainer; do
    if [ -d "$BACKUP_DIR/$service" ]; then
        echo "Restoring $service data..."
        rm -rf "$DATA_DIR/$service/*"
        cp -r "$BACKUP_DIR/$service/." "$DATA_DIR/$service/"
    else
        echo "No backup found for $service."
    fi
done

# Restore configuration
echo "Restoring configuration files..."

for service in adguard unbound caddy homeassistant; do
    if [ -d "$BACKUP_DIR/config/$service" ]; then
        echo "Restoring $service configuration..."
        rm -rf "$CONFIG_DIR/$service/*"
        cp -r "$BACKUP_DIR/config/$service/." "$CONFIG_DIR/$service/"
    else
        echo "No backup found for $service configuration."
    fi
done

echo "Restore completed."