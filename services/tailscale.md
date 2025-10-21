# Tailscale VPN Setup

This guide provides instructions for running Tailscale using the dual-configuration setup in `services/tailscale.yml`. The configuration supports both server deployments and Raspberry Pi exit node setups.

## Configuration Options

This setup includes two Tailscale configurations:

- **`tailscale-server`** (`serv` profile): Standard Tailscale client for server deployments
- **`tailscale-pi`** (`pi` profile): Exit node configuration for Raspberry Pi with route advertising

## Prerequisites

### 1. Enable IP Forwarding (Pi Profile Only)

If using the Pi profile as an exit node, you must enable IP forwarding on the host system:

```bash
# Enable IP forwarding permanently
echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf
echo 'net.ipv6.conf.all.forwarding=1' | sudo tee -a /etc/sysctl.conf

# Apply the changes immediately
sudo sysctl -p
```

### 2. Environment Variables

Create a `.env` file in the homelab root directory with your Tailscale configuration:

**For Server Profile (`serv`):**
```bash
TS_AUTHKEY=your_tailscale_auth_key_here
TS_HOSTNAME=your-server-name
TS_ARGS=--ssh  # Optional: enable SSH access
BASE=/path/to/your/data  # Base path for data storage
TS_STATE_SUFFIX=primary  # Optional: state directory suffix
```

**For Pi Profile (`pi`):**
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

From the homelab root directory, choose the appropriate profile:

**For Server Deployment:**
```bash
docker compose --profile serv up -d
```

**For Raspberry Pi Exit Node:**
```bash
docker compose --profile pi up -d
```

### 2. Configure in Tailscale Admin

**For Pi Profile (Exit Node Setup):**
1. Go to https://login.tailscale.com/admin/machines
2. Find your Raspberry Pi device
3. Click the "..." menu next to it
4. Enable "Use as exit node"
5. Approve subnet routes for `192.168.0.0/24` if needed

**For Server Profile:**
1. Go to https://login.tailscale.com/admin/machines
2. Find your server device
3. Configure any additional settings as needed

### 3. Configure Client Devices

On your phone or other devices with the Tailscale app:

1. Open the Tailscale app
2. Go to Settings → Use exit node
3. Select your Raspberry Pi from the list
4. Enable "Use exit node"

## What Each Configuration Does

### Server Profile (`tailscale-server`)
- **Standard Client**: Connects your server to the Tailscale network
- **Configurable Storage**: Uses `${BASE}` path for flexible data storage
- **Custom Arguments**: Supports additional Tailscale arguments via `${TS_ARGS}`
- **User Permissions**: Runs with specific user/group (1001:3001)

### Pi Profile (`tailscale-pi`) 
- **Exit Node**: Routes all internet traffic from your devices through the Raspberry Pi
- **Subnet Routes**: Allows access to your local network (192.168.0.0/24) from remote devices
- **Direct Storage**: Uses host paths `/etc/tailscale` for simpler setup
- **DNS**: Uses Tailscale's DNS settings for better integration

## Troubleshooting

### Check IP Forwarding Status
```bash
cat /proc/sys/net/ipv4/ip_forward
# Should return 1
```

### View Container Logs

**For Server Profile:**
```bash
docker logs -f tailscale
```

**For Pi Profile:**
```bash
docker logs -f tailscale-pi
```

### Verify Tailscale Status

**For Server Profile:**
```bash
docker exec tailscale tailscale status
```

**For Pi Profile:**
```bash
docker exec tailscale-pi tailscale status
```

### Test Connectivity

**For Pi Profile (Exit Node):**
From a remote device connected to Tailscale:
```bash
# Test access to local network
ping 192.168.0.1

# Check exit node status
curl ifconfig.me
# Should show your home IP address when exit node is active
```

**For Server Profile:**
```bash
# Test Tailscale connectivity to your server
ping your-server-tailscale-ip
```

## Security Notes

### For Pi Profile (Exit Node)
- The exit node will route ALL internet traffic through your home connection
- Make sure your home internet connection can handle the additional traffic
- Consider bandwidth limitations and data caps
- Only enable exit node functionality for trusted devices

### For Server Profile
- Ensure proper firewall configuration on your server
- Use strong authentication keys and rotate them regularly
- Monitor access logs for unauthorized usage
- Consider enabling SSH access only for trusted networks

## Profile Selection

Choose the appropriate profile based on your deployment:
- Use `--profile serv` for server deployments where you want standard Tailscale connectivity
- Use `--profile pi` for Raspberry Pi deployments where you want exit node functionality with local network access