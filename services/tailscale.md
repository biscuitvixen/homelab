# Tailscale VPN Exit Node Setup

This guide provides instructions for running Tailscale as a VPN exit node on your Raspberry Pi using the configuration in `services/tailscale.yml`.

## Prerequisites

### 1. Enable IP Forwarding on the Host (Raspberry Pi)

Before running the container, you must enable IP forwarding on the Raspberry Pi host system:

```bash
# Enable IP forwarding permanently
echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf
echo 'net.ipv6.conf.all.forwarding=1' | sudo tee -a /etc/sysctl.conf

# Apply the changes immediately
sudo sysctl -p
```

### 2. Environment Variables

Create a `.env` file in the homelab root directory with your Tailscale configuration:

```bash
TS_AUTHKEY=your_tailscale_auth_key_here
TS_HOSTNAME=raspberry-pi-exit-node
```

To get an auth key:
1. Go to https://login.tailscale.com/admin/settings/keys
2. Generate a new auth key
3. Copy it to your `.env` file

## Setup Instructions

### 1. Start the Container

From the homelab root directory:

```bash
docker-compose up -d tailscale
```

### 2. Approve Exit Node in Tailscale Admin

1. Go to https://login.tailscale.com/admin/machines
2. Find your Raspberry Pi device
3. Click the "..." menu next to it
4. Enable "Use as exit node"

### 3. Configure Client Devices

On your phone or other devices with the Tailscale app:

1. Open the Tailscale app
2. Go to Settings → Use exit node
3. Select your Raspberry Pi from the list
4. Enable "Use exit node"

## What This Does

- **Exit Node**: Routes all internet traffic from your devices through the Raspberry Pi
- **Subnet Routes**: Allows access to your local network (192.168.1.0/24) from remote devices
- **DNS**: Uses Tailscale's DNS settings for better integration

## Troubleshooting

### Check IP Forwarding Status
```bash
cat /proc/sys/net/ipv4/ip_forward
# Should return 1
```

### View Container Logs
```bash
docker-compose logs -f tailscale
```

Or from the homelab root:
```bash
docker logs -f tailscale
```

### Verify Tailscale Status
```bash
docker exec tailscale tailscale status
```

### Test Connectivity
From a remote device connected to Tailscale:
```bash
# Test access to local network
ping 192.168.1.1

# Check exit node status
curl ifconfig.me
# Should show your home IP address when exit node is active
```

## Security Notes

- The exit node will route ALL internet traffic through your home connection
- Make sure your home internet connection can handle the additional traffic
- Consider bandwidth limitations and data caps
- Only enable exit node functionality for trusted devices