# 🌐 NetMounter

<p align="center">
  <img src="site/assets/logo.png" alt="NetMounter Icon" width="128" height="128">
</p>

<p align="center">
  <strong>macOS Menu Bar Network Drive Mounting Tool</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-blue" alt="Platform">
  <img src="https://img.shields.io/badge/swift-5.9-orange" alt="Swift">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README_CN.md">中文</a>
</p>

---

## ✨ Features

- 🖥️ **Menu Bar App** - Lightweight menu bar application, mount with one click
- 🔌 **Multi-Protocol** - SMB, NFS, AFP, WebDAV
- 🤖 **Auto-Mount** - Automatically mount shares based on network environment
- 🔐 **Secure Storage** - Passwords securely stored in macOS Keychain
- 🎨 **Liquid Glass UI** - Beautiful frosted glass interface design
- 🚀 **Launch at Login** - Support for automatic startup

## 🚀 Quick Start

### [Download](https://github.com/jasine/net-mounter/releases)

### Usage

1. Launch **NetMounter** from `/Applications`
2. Click the menu bar icon 📁
3. Click `+` to add a server
4. Enter connection details and save
5. One-click mount!


## 📋 Supported Protocols

| Protocol | Use Case | Status |
|----------|----------|--------|
| **SMB** | Windows/NAS file sharing | ✅ |
| **NFS** | Linux/Unix file sharing | ✅ |
| **AFP** | Apple file sharing (legacy Mac) | ✅ |
| **WebDAV** | Network storage (Nextcloud, etc.) | ✅ |

## ⚙️ Auto-Mount

NetMounter can automatically mount shares based on network environment:

1. Open Settings
2. Add auto-mount rules for a server
3. Select target network (SSID or wired connection)
4. Automatically mounts when connected to specified network

## 🔒 Security

- Passwords stored securely using macOS Keychain
- No sensitive information written to config files
- Runs locally, no network tracking

## 🛠️ Development

### Requirements

- macOS 13.0+
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

# Clean build artifacts
make clean
```


## 📄 License

MIT License - See [LICENSE](LICENSE)

---

<p align="center">
  Made with ❤️ for macOS
</p>
