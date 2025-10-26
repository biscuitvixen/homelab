In order to be reverse-proxied by caddy, HA needs to trust the reverse proxy's IP address.

To do this, add the following lines to your `configuration.yaml` file in your Home Assistant configuration directory:

```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 172.18.0.0/16
```
