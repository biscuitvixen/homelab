#!/bin/bash

# Define backup directories
BACKUP_DIR="/path/to/backup"  # Change this to your desired backup location
DATA_DIR="/path/to/data"       # Change this to your data directory

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Backup data directories
tar -czf "$BACKUP_DIR/adguard_backup_$(date +%Y%m%d).tar.gz" "$DATA_DIR/adguard"
tar -czf "$BACKUP_DIR/homeassistant_backup_$(date +%Y%m%d).tar.gz" "$DATA_DIR/homeassistant"
tar -czf "$BACKUP_DIR/mosquitto_backup_$(date +%Y%m%d).tar.gz" "$DATA_DIR/mosquitto"
tar -czf "$BACKUP_DIR/caddy_backup_$(date +%Y%m%d).tar.gz" "$DATA_DIR/caddy"
tar -czf "$BACKUP_DIR/portainer_backup_$(date +%Y%m%d).tar.gz" "$DATA_DIR/portainer"

# Backup configuration directories
tar -czf "$BACKUP_DIR/adguard_config_backup_$(date +%Y%m%d).tar.gz" "config/adguard"
tar -czf "$BACKUP_DIR/unbound_config_backup_$(date +%Y%m%d).tar.gz" "config/unbound"
tar -czf "$BACKUP_DIR/caddy_config_backup_$(date +%Y%m%d).tar.gz" "config/caddy"
tar -czf "$BACKUP_DIR/homeassistant_config_backup_$(date +%Y%m%d).tar.gz" "config/homeassistant"

echo "Backup completed successfully!"