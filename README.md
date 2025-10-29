# Homelab

A modular, multi-purpose homelab infrastructure designed to run on both Proxmox LXC containers and Raspberry Pi devices. This project provides a comprehensive suite of self-hosted services including DNS management, reverse proxy, VPN access, and home automation, all orchestrated through Docker Compose with profile-based deployment.

## Project Structure

```
homelab/
├── docker-compose.yml          # Main orchestration file with profile support
├── .env.example                # Template for environment variables
├── .gitignore                  # Git exclusions
├── README.md                   # This file
│
├── services/                   # Individual service definitions
│   ├── adguard.yml            # DNS ad-blocking & filtering
│   ├── caddy.yml              # Reverse proxy with automatic HTTPS
│   ├── homeassistant.yml      # Home automation platform
│   ├── homeassistant.md       # HA reverse proxy configuration
│   ├── mosquitto.yml          # MQTT broker for IoT
│   ├── portainer.yml          # Docker container management UI
│   ├── samba.yml              # Network file sharing (optional)
│   ├── tailscale.yml          # VPN with dual-mode support
│   ├── tailscale.md           # Detailed Tailscale setup guide
│   ├── unbound.yml            # Recursive DNS resolver
│   └── watchtower.yml         # Automatic container updates
│
├── configs/                    # Service configuration files
│   ├── caddy/
│   │   └── Caddyfile          # Reverse proxy & internal TLS config
│   ├── mosquitto/
│   │   └── mosquitto.conf     # MQTT broker configuration
│   └── unbound/
│       └── unbound.conf       # DNS resolver configuration
│
├── web/                        # Static websites served by Caddy
│   └── lab.lan/               # Homelab dashboard
│       ├── index.html         # Main page
│       ├── app.js             # Vue 3 application
│       ├── services.json      # Service links configuration
│       └── styles.css         # Modern responsive styling
│
└── scripts/                    # Maintenance scripts
    ├── backup.sh              # Backup data and configs
    ├── restore.sh             # Restore from backup
    └── update.sh              # Update all services
```

## Deployment Profiles

This homelab uses Docker Compose profiles to support different deployment scenarios:

### Available Profiles

- **`serv`** - Full server deployment (Proxmox LXC)
  - Includes all core services
  - Uses `${BASE}` path for flexible storage locations
  - Tailscale with custom routing arguments

- **`pi`** - Raspberry Pi deployment
  - Tailscale exit node configuration
  - Advertises local network routes (192.168.0.0/24)
  - Uses direct host paths for simpler setup

- **`dns`** - DNS services only
  - AdGuard Home
  - Unbound resolver
  - Caddy reverse proxy

- **`iot`** - IoT & home automation
  - Home Assistant
  - Mosquitto MQTT broker

## Services Overview

### Core Infrastructure
- **Caddy** - Modern reverse proxy with automatic internal TLS certificates
  - Serves homelab dashboard at https://lab.lan
  - Reverse proxies for AdGuard, Home Assistant, TrueNAS, and Proxmox
  - Automatic certificate management

- **Tailscale** - Zero-config VPN
  - **Server mode**: Standard client with customizable routes
  - **Pi mode**: Exit node with subnet routing for remote LAN access
  - See [services/tailscale.md](services/tailscale.md) for detailed setup

### DNS & Security
- **AdGuard Home** - Network-wide ad blocking and DNS filtering
  - Custom upstream DNS via Unbound
  - Web interface at https://adguard.lan

- **Unbound** - Validating, recursive DNS resolver
  - DNSSEC validation
  - Privacy-focused configuration
  - Serves as upstream for AdGuard

### Home Automation & IoT
- **Home Assistant** - Local-first home automation
  - Network mode: host (for device discovery)
  - Reverse proxied at https://home.lan
  - See [services/homeassistant.md](services/homeassistant.md) for proxy configuration

- **Mosquitto** - Lightweight MQTT broker
  - Supports WebSockets (port 9001)
  - Anonymous access enabled (configure as needed)

### Management & Monitoring
- **Watchtower** - Automatic container updates
  - Runs daily at 5 AM
  - Cleans up old images
  - Monitors all containers (including stopped ones)

- **Portainer** - Web-based Docker management
  - Container deployment and monitoring
  - Full Docker engine access

### Optional Services
- **Samba** - Network file sharing (currently disabled)
  - SMB/CIFS file server
  - User-based authentication

## Service Status

Track the working status of each service:

### Core Services
- ~~ **Samba** - Network file sharing~~
- [x] **Tailscale** - VPN access (server & Pi configurations)
- [x] **AdGuard** - DNS ad blocking
- [x] **Unbound** - DNS resolver
- [x] **Caddy** - Reverse proxy & HTTPS

### IoT & Home Automation
- [x] **Home Assistant** - Home automation
- [x] **Mosquitto** - MQTT broker

### Infrastructure
- ~~**Portainer** - Container management~~
- [x] **Watchtower** - Auto-updates

## Quick Start

### 1. Clone and Configure

```bash
git clone <your-repo-url> homelab
cd homelab
cp .env.example .env
```

### 2. Edit Environment Variables

```bash
nano .env
```

Required variables:
- `TZ` - Your timezone (e.g., `Europe/London`)
- `BASE` - Base path for data storage (e.g., `/mnt/storage`)
- `PUID`/`PGID` - User/group IDs for file permissions
- `TS_AUTHKEY` - Tailscale authentication key
- `TS_HOSTNAME` - Hostname for your Tailscale node

### 3. Deploy Services

**For Proxmox LXC (full server):**
```bash
docker compose --profile serv up -d
```

**For Raspberry Pi (exit node):**
```bash
docker compose --profile pi up -d
```

**DNS services only:**
```bash
docker compose --profile dns up -d
```

**IoT services only:**
```bash
docker compose --profile iot up -d
```

**Combine profiles:**
```bash
docker compose --profile serv --profile iot up -d
```

## Web Dashboard

Access the homelab dashboard at https://lab.lan (after configuring Caddy and adding the internal CA certificate to your devices).

Features:
- Quick links to all services
- Certificate download button
- Responsive design with dark mode support
- Built with Vue 3

Services are configured in [`web/lab.lan/services.json`](web/lab.lan/services.json).

## Network Architecture

```
Internet
    ↓
Tailscale VPN (100.x.x.x)
    ↓
┌─────────────────────────────────────┐
│  Proxmox Host (192.168.0.10)        │
│  ├─ LXC Container (Homelab)         │
│  │  ├─ Caddy :80, :443              │
│  │  ├─ AdGuard :53                  │
│  │  ├─ Unbound :66                  │
│  │  └─ Mosquitto :1883, :9001       │
│  │                                  │
│  └─ Other VMs/LXCs                  │
├─────────────────────────────────────┤
│  TrueNAS (192.168.0.11)             │
│  Home Assistant (192.168.0.12)      │
└─────────────────────────────────────┘
```

## Service Domains

All services use internal TLS via Caddy:
- **Dashboard**: https://lab.lan
- **AdGuard**: https://adguard.lan
- **Home Assistant**: https://home.lan
- **Proxmox**: https://pve.lan
- **TrueNAS**: https://truenas.lan

## Maintenance

### Backups
```bash
./scripts/backup.sh
```
Backs up all data directories and configurations to the specified backup location.

### Restore
```bash
./scripts/restore.sh
```
Restores from the latest backup.

### Updates
```bash
./scripts/update.sh
```
Pulls latest images and restarts services.

## Tailscale Setup

For detailed Tailscale configuration including:
- IP forwarding setup
- Exit node configuration
- Subnet route advertising
- Troubleshooting

See the comprehensive guide: [services/tailscale.md](services/tailscale.md)

## Health Checks

Most services include health checks for monitoring:
- **AdGuard**: HTTP check on localhost
- **Unbound**: DNS query test
- **Caddy**: Configuration validation
- **Home Assistant**: HTTP endpoint check
- **Tailscale**: Peer status check

View health status:
```bash
docker compose ps
```

## Security Notes

- All web services use internal TLS certificates via Caddy
- Tailscale provides encrypted VPN access
- AdGuard filters DNS queries and blocks ads/trackers
- DNSSEC validation enabled in Unbound
- Home Assistant configured to trust reverse proxy

## Troubleshooting

### View logs
```bash
docker compose logs -f <service-name>
```

### Restart a service
```bash
docker compose restart <service-name>
```

### Check health status
```bash
docker compose ps
docker inspect <container-name> | grep -A 10 Health
```

### Common Issues

**Tailscale not connecting:**
- See [services/tailscale.md](services/tailscale.md)

**DNS not resolving:**
- Ensure AdGuard upstream is set to `unbound:53`
- Check Unbound is healthy: `docker compose ps unbound`
- Ensure rewrites are correct in AdGuard settings pointing to LXC

**Certificate errors:**
- Download and install Caddy's internal CA certificate from https://lab.lan

