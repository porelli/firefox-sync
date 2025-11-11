# Firefox Sync with Podman

This guide covers running Firefox Sync with Podman, including rootless configurations and systemd integration via Quadlets.

## Table of Contents

- [Why Podman?](#why-podman)
- [Rootless Podman Compatibility](#rootless-podman-compatibility)
- [Installation Methods](#installation-methods)
  - [Method 1: Using podman-compose (Recommended for Testing)](#method-1-using-podman-compose)
  - [Method 2: Using Quadlets (Recommended for Production)](#method-2-using-quadlets)
- [Troubleshooting](#troubleshooting)
- [Performance Considerations](#performance-considerations)

## Why Podman?

Podman is a daemonless container engine that offers several advantages:

- **Rootless by default**: Run containers without root privileges
- **Systemd integration**: Native integration with systemd via Quadlets
- **Docker-compatible**: Drop-in replacement for Docker in most cases
- **Security**: Better isolation and security model
- **No daemon**: Containers run as child processes

## Rootless Podman Compatibility

This project has been specifically optimized for rootless podman environments:

### Improvements Made

1. **Extended Wait Times**: The database initialization script waits up to 2 minutes (vs 50 seconds) for migrations to complete
2. **Proper Table Checking**: Verifies all required tables exist before initialization
3. **Better Error Handling**: Clear progress indicators and error messages
4. **Dynamic Configuration**: MAX_USERS stored in database, updatable without rebuilding
5. **Podman-Specific Overrides**: Optional `docker-compose.podman.yml` with rootless optimizations

### Known Considerations

- **Slower Startup**: Rootless containers may start slower than rootful ones
- **Volume Permissions**: Handled automatically with `userns_mode: keep-id`
- **SELinux**: Disabled via `security_opt: label=disable` in podman override file

## Installation Methods

### Prerequisites

1. Install Podman:
   ```bash
   # Fedora/RHEL/CentOS
   sudo dnf install podman podman-compose
   
   # Ubuntu/Debian
   sudo apt install podman podman-compose
   
   # Arch Linux
   sudo pacman -S podman podman-compose
   ```

2. For rootless setup, configure subuid/subgid:
   ```bash
   # Check if already configured
   grep $USER /etc/subuid /etc/subgid
   
   # If not configured, add entries (requires root)
   sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER
   ```

3. Run the environment preparation script:
   ```bash
   ./prepare_environment.sh
   ```

### Method 1: Using podman-compose

This method is similar to docker-compose and good for testing.

#### Basic Usage

```bash
# Start services
podman-compose up -d

# With podman-specific optimizations
podman-compose -f docker-compose.yml -f docker-compose.podman.yml up -d

# View logs
podman-compose logs -f

# Stop services
podman-compose down
```

#### Rootless Considerations

When using rootless podman-compose:

1. **Port Binding**: Ports below 1024 require special handling
   ```bash
   # If using port 80, you need to allow it
   sudo sysctl net.ipv4.ip_unprivileged_port_start=80
   ```

2. **Volume Permissions**: The podman override file handles this automatically

3. **Systemd Integration**: See Method 2 for better systemd integration

### Method 2: Using Quadlets

Quadlets provide native systemd integration for Podman. This is the **recommended method for production**.

#### What are Quadlets?

Quadlets are systemd unit files that Podman converts into container configurations. They provide:

- Native systemd integration
- Automatic dependency management
- Better logging via journald
- Easier service management
- Automatic updates support

#### Setup

1. Run the environment preparation script and choose Quadlets when prompted:
   ```bash
   ./prepare_environment.sh
   ```
   
   When asked about deployment method, select option 2 (Quadlets).
   
   The script will automatically:
   - Create your `.env` file with configuration
   - Copy quadlet files to `~/.config/containers/systemd/`
   - Replace environment variables with your configuration
   - Reload systemd

2. Start the services:
   ```bash
   # Start all services (init will start dependencies automatically)
   systemctl --user start firefox-sync-tokenserver-db-init.service
   
   # Or start individual services
   systemctl --user start firefox-sync-syncstorage.service
   ```

3. Enable services to start on boot:
   ```bash
   systemctl --user enable firefox-sync-syncstorage.service
   systemctl --user enable firefox-sync-syncstorage-db.service
   systemctl --user enable firefox-sync-tokenserver-db.service
   systemctl --user enable firefox-sync-tokenserver-db-init.service
   ```

5. Enable lingering (optional - allows services to start without login):
   ```bash
   loginctl enable-linger $USER
   ```

#### Managing Quadlet Services

```bash
# Check status
systemctl --user status firefox-sync-syncstorage.service

# View logs
journalctl --user -u firefox-sync-syncstorage.service -f

# Restart a service
systemctl --user restart firefox-sync-syncstorage.service

# Stop all services
systemctl --user stop firefox-sync-syncstorage.service
systemctl --user stop firefox-sync-syncstorage-db.service
systemctl --user stop firefox-sync-tokenserver-db.service

# Update containers (with AutoUpdate enabled)
podman auto-update
systemctl --user restart firefox-sync-syncstorage.service
```

#### Updating Configuration

To update MAX_USERS or other settings:

1. Edit your `.env` file
2. Re-run the preparation script (it will detect existing config and update quadlets):
   ```bash
   ./prepare_environment.sh
   ```
   Or manually update quadlets by re-running with the same answers
3. Restart the init service:
   ```bash
   systemctl --user restart firefox-sync-tokenserver-db-init.service
   ```

## Troubleshooting

### Issue: "Table 'tokenserver.users' doesn't exist"

This was the original rootless podman issue. If you still see this:

1. Check that you're using the latest init image:
   ```bash
   podman pull ghcr.io/porelli/firefox-sync:syncstorage-rs-mysql-init-latest
   ```

2. Check the init container logs:
   ```bash
   # With podman-compose
   podman-compose logs tokenserver_db_init
   
   # With quadlets
   journalctl --user -u firefox-sync-tokenserver-db-init.service
   ```

3. The script should show "Waiting for tables..." messages. If it times out, increase the wait time in the init script.

### Issue: Permission Denied on Volumes

```bash
# Check volume ownership
podman volume inspect firefox-sync-syncstorage-db

# If using podman-compose, ensure you're using the podman override:
podman-compose -f docker-compose.yml -f docker-compose.podman.yml up -d
```

### Issue: Services Not Starting with Quadlets

```bash
# Check systemd status
systemctl --user status firefox-sync-syncstorage.service

# Reload systemd if you made changes
systemctl --user daemon-reload

# Check for errors in journal
journalctl --user -xe
```

### Issue: Port Already in Use

```bash
# Find what's using the port
sudo ss -tulpn | grep :5000

# Change the port in .env and re-run setup
```

### Issue: Slow Startup in Rootless Mode

This is normal. Rootless containers start slower than rootful ones. The init script now waits up to 2 minutes to accommodate this.

If you need faster startup:
1. Consider using rootful podman (requires sudo)
2. Increase system resources
3. Use SSD storage for volumes

## Performance Considerations

### Rootless vs Rootful

**Rootless** (Recommended for security):
- Better security isolation
- No root privileges required
- Slightly slower performance
- May have permission issues with some volumes

**Rootful** (Better performance):
- Faster startup and runtime
- Easier volume management
- Requires root privileges
- Less secure

### Storage Drivers

Podman supports multiple storage drivers. For best performance:

```bash
# Check current driver
podman info | grep graphDriverName

# overlay is fastest (default on most systems)
# vfs is slowest but most compatible
```

### Resource Limits

With rootless podman, you can set resource limits without root:

```bash
# In docker-compose.yml or quadlet files, add:
# deploy:
#   resources:
#     limits:
#       cpus: '2'
#       memory: 2G
```

### Volume Performance

For better volume performance:

1. Use named volumes (already configured)
2. Ensure volumes are on fast storage (SSD)
3. Consider using `:Z` or `:z` mount options for SELinux systems

## Migration from Docker

If you're migrating from Docker:

1. **Export volumes** (if you have existing data):
   ```bash
   docker run --rm -v syncstorage-db:/data -v $(pwd):/backup alpine tar czf /backup/syncstorage-db.tar.gz /data
   ```

2. **Import to Podman**:
   ```bash
   podman volume create firefox-sync-syncstorage-db
   podman run --rm -v firefox-sync-syncstorage-db:/data -v $(pwd):/backup alpine tar xzf /backup/syncstorage-db.tar.gz -C /
   ```

3. **Use podman-compose** with the same docker-compose.yml file

## Additional Resources

- [Podman Documentation](https://docs.podman.io/)
- [Quadlet Documentation](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
- [Rootless Podman Guide](https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md)
- [Firefox Sync Issue #11](https://github.com/porelli/firefox-sync/issues/11) - Original rootless podman issue

## Support

If you encounter issues:

1. Check this guide's troubleshooting section
2. Review the logs (podman-compose logs or journalctl)
3. Open an issue on GitHub with:
   - Your podman version (`podman --version`)
   - Whether you're using rootless or rootful
   - Relevant logs
   - Your configuration (with secrets redacted)