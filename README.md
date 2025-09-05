# Asteria Home Server

Welcome to the Asteria Home Server project! This project aims to set up a variety of useful services on a Raspberry Pi 4 (named Asteria) using Docker and Docker Compose. The services are organized in a modular way for easy maintenance and scalability.

## Project Structure

The project is organized as follows:

```
asteria-homeserver
├── docker-compose.yml          # Central Docker Compose file
├── .env                        # Environment variables for services
├── .env.example                # Example environment file with placeholders
├── services                    # Directory containing individual service configurations
│   ├── samba                   # Samba network storage service
│   ├── tailscale               # Tailscale VPN service
│   ├── adguard                 # AdGuard service
│   ├── unbound                 # Unbound DNS service
│   ├── caddy                   # Caddy web server
│   ├── homeassistant           # Home Assistant service
│   ├── mosquitto               # Mosquitto MQTT broker
│   ├── portainer               # Portainer for managing Docker containers
│   ├── watchtower              # Watchtower for automatic updates
│   └── uptime-kuma             # Uptime Kuma for service monitoring
├── data                        # Persistent data storage for services
├── config                      # Configuration files for services
└── scripts                     # Scripts for backup, restore, and update
```

## Services Overview

- **Samba**: Network file sharing service for accessing storage across devices.
- **Tailscale**: A VPN service that allows secure access to your home network from anywhere.
- **AdGuard**: A network-wide ad blocker that enhances your browsing experience.
- **Unbound**: A validating, recursive, and caching DNS resolver.
- **Caddy**: A modern web server with automatic HTTPS.
- **Home Assistant**: A home automation platform that focuses on privacy and local control.
- **Mosquitto**: An MQTT broker for IoT devices.
- **Portainer**: A web interface for managing Docker containers.
- **Watchtower**: A service that automatically updates running Docker containers.
- **Uptime Kuma**: A self-hosted status monitoring solution.

## Service Status

Track the working status of each service:

### Core Services
- [x] **Samba** - Network file sharing
- [x] **Tailscale** - VPN access
- [ ] **AdGuard** - DNS ad blocking
- [ ] **Unbound** - DNS resolver

### Web Services  
- [ ] **Caddy** - Reverse proxy & HTTPS
- [ ] **Home Assistant** - Home automation
- [ ] **Uptime Kuma** - Status monitoring

### Infrastructure
- [ ] **Mosquitto** - MQTT broker
- [ ] **Portainer** - Container management
- [ ] **Watchtower** - Auto-updates

## Setup Instructions

1. **Clone the Repository**: Clone this repository to your Raspberry Pi.
2. **Configure Environment Variables**: Edit the `.env` file to set up your environment variables.
3. **Add Secrets**: Fill in the `secrets.env` file with any sensitive information required by your services.
4. **Start Services**: Run `docker-compose up -d` from the root of the project to start all services.
5. **Access Services**: Use the respective URLs and ports to access each service.

## Backup and Restore

- Use `scripts/backup.sh` to back up your data and configurations.
- Use `scripts/restore.sh` to restore from a backup.

## Updating Services

Run `scripts/update.sh` to update all services to their latest versions.

## Contributing

Feel free to contribute to this project by adding new services or improving existing ones. Make sure to follow the project's structure for consistency.
