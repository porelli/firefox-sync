# Podman Quadlet Files

This directory contains Podman Quadlet files for systemd integration. Quadlets provide native systemd support for Podman containers.

## What are Quadlets?

Quadlets are systemd unit files that Podman automatically converts into container configurations. They provide:

- **Native systemd integration**: Manage containers like any other systemd service
- **Automatic dependency management**: Services start in the correct order
- **Better logging**: Integrated with journald
- **Automatic updates**: Built-in support for container updates
- **User-level services**: Perfect for rootless Podman

## Files in this Directory

### Network and Volumes
- `firefox-sync-network.network` - Creates the container network
- `firefox-sync-syncstorage-db.volume` - Volume for syncstorage database
- `firefox-sync-tokenserver-db.volume` - Volume for tokenserver database

### Containers
- `firefox-sync-syncstorage-db.container` - Syncstorage MariaDB database
- `firefox-sync-tokenserver-db.container` - Tokenserver MariaDB database
- `firefox-sync-syncstorage.container` - Main Firefox Sync service
- `firefox-sync-tokenserver-db-init.container` - Database initialization (runs once)

### Setup Script
- `setup-quadlets.sh` - Automated setup script that:
  - Copies files to `~/.config/containers/systemd/`
  - Replaces environment variables from your `.env` file
  - Reloads systemd

## Quick Start

1. Run the main setup script and choose Quadlets (option 2) when prompted:
   ```bash
   cd ../..
   ./prepare_environment.sh
   ```
   
   The script will automatically set up quadlets for you.

2. Start the services:
   ```bash
   systemctl --user start firefox-sync-tokenserver-db-init.service
   ```

3. Enable services to start on boot:
   ```bash
   systemctl --user enable firefox-sync-syncstorage.service
   systemctl --user enable firefox-sync-syncstorage-db.service
   systemctl --user enable firefox-sync-tokenserver-db.service
   systemctl --user enable firefox-sync-tokenserver-db-init.service
   ```

4. (Optional) Enable lingering to start services without login:
   ```bash
   loginctl enable-linger $USER
   ```

## Managing Services

### Check Status
```bash
systemctl --user status firefox-sync-syncstorage.service
```

### View Logs
```bash
# Follow logs in real-time
journalctl --user -u firefox-sync-syncstorage.service -f

# View all logs
journalctl --user -u firefox-sync-syncstorage.service

# View logs from all firefox-sync services
journalctl --user -u 'firefox-sync-*' -f
```

### Restart Services
```bash
systemctl --user restart firefox-sync-syncstorage.service
```

### Stop Services
```bash
systemctl --user stop firefox-sync-syncstorage.service
systemctl --user stop firefox-sync-syncstorage-db.service
systemctl --user stop firefox-sync-tokenserver-db.service
```

## Updating Configuration

If you need to change settings (like MAX_USERS):

1. Edit your `.env` file in the project root
2. Re-run the main setup script (it will update quadlets):
   ```bash
   cd ../..
   ./prepare_environment.sh
   ```
   Choose option 2 (Quadlets) again when prompted
3. Restart the affected services:
   ```bash
   systemctl --user restart firefox-sync-tokenserver-db-init.service
   ```

## Automatic Updates

The quadlet files include `AutoUpdate=registry` which enables automatic container updates.

To update containers:
```bash
# Check for updates
podman auto-update --dry-run

# Apply updates
podman auto-update

# Restart services to use new images
systemctl --user restart firefox-sync-syncstorage.service
```

You can also set up a systemd timer for automatic updates:
```bash
systemctl --user enable --now podman-auto-update.timer
```

## Troubleshooting

### Services Won't Start

1. Check systemd status:
   ```bash
   systemctl --user status firefox-sync-syncstorage.service
   ```

2. Check for errors:
   ```bash
   journalctl --user -xe
   ```

3. Verify quadlet files were installed:
   ```bash
   ls -la ~/.config/containers/systemd/
   ```

4. Reload systemd:
   ```bash
   systemctl --user daemon-reload
   ```

### Environment Variables Not Working

The setup script replaces `%VARIABLE%` placeholders with values from your `.env` file. If variables aren't being replaced:

1. Ensure `.env` exists in the project root
2. Check that variables are defined in `.env`
3. Re-run `./prepare_environment.sh` and choose Quadlets (option 2)

### Permission Issues

For rootless Podman, ensure:
1. You're running commands as your regular user (not root)
2. Subuid/subgid are configured:
   ```bash
   grep $USER /etc/subuid /etc/subgid
   ```

### Port Conflicts

If port 5000 (or your configured port) is in use:
1. Edit `.env` and change `CONTAINER_EXPORT_PORT`
2. Re-run `./setup-quadlets.sh`
3. Restart services

## Advanced Configuration

### Custom Quadlet Location

By default, quadlets are installed to `~/.config/containers/systemd/`. To use a different location:

```bash
# System-wide (requires root)
sudo cp *.{network,volume,container} /etc/containers/systemd/
sudo systemctl daemon-reload

# Custom user location
export QUADLET_DIR=/path/to/custom/location
./setup-quadlets.sh
```

### Resource Limits

You can add resource limits to container files:

```ini
[Container]
# ... existing config ...
Memory=2G
CPUQuota=200%
```

### Additional Networks

To connect containers to additional networks, add to the container file:

```ini
[Container]
# ... existing config ...
Network=firefox-sync-network.network
Network=another-network.network
```

## More Information

- [Podman Quadlet Documentation](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
- [Main Podman Guide](../../PODMAN.md)
- [Project README](../../README.md)