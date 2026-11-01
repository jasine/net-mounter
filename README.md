# 🌐 NetMounter

<p align="center">
  <img src="docs/assets/logo.png" alt="NetMounter Icon" width="128" height="128">
</p>

<p align="center">
  <strong>macOS Menu Bar Network Drive Mounting Tool</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue" alt="Platform">
  <img src="https://img.shields.io/badge/swift-5.9-orange" alt="Swift">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README_CN.md">中文</a>
</p>

---

## ✨ Features

- 🖥️ **Menu Bar App** - Lightweight menu bar application, mount with one click
- 🔌 **Multi-Protocol** - SMB, AFP, NFS, WebDAV
- 📡 **Network Discovery** - Auto-discover servers and shares via Bonjour/mDNS
- 🤖 **Auto-Mount** - Automatically mount shares based on network environment
- 🌐 **VPN Awareness** - Auto-detect VPN routing and mount/unmount servers accordingly
- 😴 **Sleep/Wake Reconnect** - Gracefully disconnect before sleep and auto-reconnect on wake
- 🧟 **Zombie Mount Healing** - Detect and recover unresponsive mounts automatically
- 🔔 **Notifications** - Get notified on mount success, failure, and recovery events
- 🔗 **URL Scheme Sharing** - Share server configs via `netmounter://` links for easy team setup
- 📌 **Pinned Folders** - Pin frequently used subfolders for one-click access from the server card
- 📊 **Dynamic Status Icon** - Menu bar icon reflects real-time mount status at a glance
- 🔐 **Secure Storage** - Passwords securely stored in macOS Keychain
- 🎨 **Liquid Glass UI** - Beautiful frosted glass interface design
- 🚀 **Launch at Login** - Support for automatic startup

## 🚀 Quick Start

### Install via Homebrew

```bash
brew tap jasine/tap
brew install --cask netmounter
```

### Manual Download

Download the latest DMG from [GitHub Releases](https://github.com/jasine/net-mounter/releases).

### Usage

1. Launch **NetMounter** from `/Applications`
2. Click the menu bar icon 📁
3. Click `+` to add a server manually, or click 📡 to discover servers on your network
4. Enter connection details and save
5. One-click mount!

## 🧭 Setup Guide

When adding a server manually (`+` button), fill in these fields:

| Field | What to enter | Example |
|-------|---------------|---------|
| **Name** | Any label you like | `Home NAS` |
| **Protocol** | The sharing protocol the server uses | `SMB` |
| **Hostname / IP** | IP or hostname **only** — no `smb://` prefix, no slashes | `192.168.1.50`, `nas.local`, `100.101.102.103` (Tailscale) |
| **Share Path** | For SMB/AFP: the share **name** only. For NFS: the full export path. | SMB: `media` &nbsp;·&nbsp; NFS: `/volume1/media` |
| **Username / Password** | Credentials (not needed for NFS) | `guest` |

Tips:
- For a Windows share `\\SERVER\media`, enter `SERVER` (or its IP) as the host and `media` as the share path.
- **Tailscale**: use the machine's Tailscale IP (`100.x.x.x`) or MagicDNS name as the hostname, then add the share manually — see discovery note below.
- **NFS** requires an export path and uses host-based access control, so no username/password.

## 📡 Network Discovery

NetMounter can automatically discover network servers and shares:

1. Click the 📡 (antenna) icon in the menu bar popup
2. NetMounter scans for SMB, AFP, and NFS servers via Bonjour/mDNS
3. Discovered SMB/AFP hosts are also probed for NFS (port 2049)
4. Expand a server to browse its shares (SMB shares via `smbutil`, NFS exports via `showmount`)
5. Click `+` to add any discovered share to your server list

> **Bonjour only finds hosts that advertise themselves via mDNS** — mostly NAS
> devices and Macs. Two common cases won't appear in the automatic scan:
> - **Windows shares** — Windows doesn't advertise SMB over Bonjour by default.
> - **Tailscale / VPN hosts** — mDNS is link-local and doesn't cross the tailnet.
>
> **Scan Subnet** button: probes every host on your local `/24` for SMB/AFP/NFS
> ports, which surfaces Windows shares and other non-advertising hosts on the
> same LAN. Tailscale hosts are on a routed overlay (no local subnet), so add
> those **manually** using the Tailscale IP or MagicDNS name (see Setup Guide).

## 📋 Supported Protocols

| Protocol | Use Case | Mount Method |
|----------|----------|-------------|
| **SMB** | Windows/NAS file sharing | NetFS (saved Keychain credentials or guest/session access) |
| **AFP** | Apple file sharing (legacy) | NetFS (saved Keychain credentials or guest/session access) |
| **NFS** | Linux/Unix/NAS file sharing | User-owned mount directory; optional reserved-port compatibility |
| **WebDAV** | Network storage (Nextcloud, etc.) | NetFS (saved Keychain credentials or guest/session access) |

## ⚙️ Auto-Mount

NetMounter can automatically mount shares based on network environment:

1. Open Settings
2. Add auto-mount rules for a server
3. Select target network (SSID or wired connection)
4. Automatically mounts when connected to specified network

## 🌐 VPN Awareness

NetMounter automatically detects when your servers are routed through a VPN:

- Checks the system routing table to determine if a server's traffic goes through a VPN interface (`utun`, `ipsec`, `ppp`)
- When VPN connects and a server becomes VPN-routed, it auto-mounts (if auto-mount is enabled)
- When VPN disconnects, VPN-routed servers are automatically unmounted
- No manual configuration needed — works with any VPN client

## 😴 Sleep/Wake Reconnect

Recover network mounts after waking from sleep:

- Before sleep: pauses automatic mounting and starts non-blocking graceful unmounts, with force-unmount fallback
- After wake: refreshes network detection and waits for pending cleanup before reconnecting
- Configured servers reuse their saved Keychain credentials; unmanaged mounts reuse session/guest access without showing a server login dialog
- Includes a 30-second timeout for network recovery with notification on failure

## 🔗 URL Scheme Sharing

Share server configurations with your team via links:

```
netmounter://add?host=192.168.1.100&proto=smb&share=shared&alias=NAS
```

- Click the link icon on any server card to copy its share link
- Opening the link shows a confirmation dialog before adding the server
- Duplicate servers are automatically detected and rejected
- Credentials are never included in URLs

## 🔒 Security

- Passwords stored securely using macOS Keychain
- Passwords are not written to configuration files; server addresses and settings stay in local JSON.
- Diagnostic collection is **on by default** to help improve reliability. Turn off **Settings → Diagnostics → Share diagnostic data** to stop collection.
- Sanitized error/crash reports and sampled operation timings go to Sentry (US); passwords, server addresses, share paths and raw logs are not forwarded. Sentry processes the connection IP for transport; details and limitations are documented in [SENTRY.md](SENTRY.md).

### Why different password prompts appear

- **Server password:** enter it when adding/editing a server in NetMounter. It is stored in macOS Keychain and reused for manual, automatic and wake-recovery mounts. It is not your Mac login password.
- **Keychain access/unlock:** macOS may ask permission to let NetMounter read a saved server password. This is a system authorization prompt; the app cannot bypass it or use the Keychain unlock password as a server password.
- **NFS administrator authorization:** the default NFS mode does not request administrator authorization. Only the explicit reserved-source-port compatibility mode uses elevated privileges; administrator passwords are never stored by NetMounter.
- Mounts created outside NetMounter have no app-owned credential reference. Add the server to NetMounter and save its password to use the same credential path; existing Finder/Keychain entries are not migrated or deleted automatically.

### NFS permissions and compatibility

- By default, NFS mounts use non-reserved source ports (`noresvport`) and a user-owned directory: `~/NetworkMounts/<server-id>/<export-name>`. The NAS must permit your client host and non-reserved source ports; mounting in a user directory does not bypass NAS export permissions.
- Enable **NAS requires a reserved source port** in the server settings only if the NAS is confirmed to require it. This compatibility mode uses `/Volumes` and administrator privileges. Ordinary permission errors or connection failures do not automatically enable it or trigger elevation.
- Saving a server never installs or authorizes a privileged helper. Manual reserved-port mounting can request administrator authorization. Automatic/wake mounting never prompts; use the separate **Authorize once for automatic NFS mounts…** button if you want that mode to run unattended.
- That authorization installs a persistent passwordless NFS helper for your macOS user, not a permission restricted to NetMounter. Existing helpers are not removed, and ordinary-user mounts do not use them.
- Existing connected volumes are reused, not moved or unmounted when the mode changes. The selected mode applies to the next mount after disconnection.

For release builds, a stable code-signing identity helps preserve Keychain application identity across updates. The current ad-hoc distribution does not provide that assurance; adding support for an identity is not the same as signing/notarizing a release.

## 🛠️ Development

### Requirements

- macOS 14.0+
- Xcode 15+ / Swift 5.9+
- Swift Package Manager

### Build Commands

```bash
# Run debug version
make run

# Build release version
make build

# Package as .app
make package

# Create DMG for distribution
make dmg

# Clean build artifacts
make clean
```


To package with an explicitly selected signing identity (never auto-selected):

```bash
cd NetMounter
NETMOUNTER_SIGNING_IDENTITY="Developer ID Application: Example (TEAMID)" ./package_app.sh
```

The identity and private key must already be available to `codesign`. Omitting the variable keeps local ad-hoc signing. Notarization and matching Sentry dSYM upload remain separate release steps.

## 📄 License

MIT License - See [LICENSE](LICENSE)

---

<p align="center">
  Made with ❤️ for macOS
</p>
