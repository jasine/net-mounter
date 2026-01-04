# 🌐 NetMounter

<p align="center">
  <img src="docs/assets/logo.png" alt="NetMounter Icon" width="128" height="128">
</p>

<p align="center">
  <strong>macOS 菜单栏网络驱动器挂载工具</strong>
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

## ✨ 功能特性

- 🖥️ **菜单栏常驻** - 轻量级菜单栏应用，随时一键挂载
- 🔌 **多协议支持** - SMB、AFP、WebDAV
- 🤖 **自动挂载** - 根据网络环境自动挂载指定共享
- 🔐 **安全存储** - 密码安全存储在 macOS 钥匙串
- 🎨 **Liquid Glass UI** - 精美的毛玻璃界面设计
- 🚀 **开机自启** - 支持开机自动启动

## 🚀 快速开始

### [下载](https://github.com/jasine/net-mounter/releases)

### 使用

1. 从 `/Applications` 启动 **NetMounter**
2. 点击菜单栏图标 📁
3. 点击 `+` 添加服务器
4. 输入连接信息并保存
5. 一键挂载！


## 📋 支持的协议

| 协议 | 用途 | 状态 |
|------|------|------|
| **SMB** | Windows/NAS 文件共享 | ✅ |
| **AFP** | Apple 文件共享 (旧版 Mac) | ✅ |
| **WebDAV** | 网络存储 (Nextcloud 等) | ✅ |

## ⚙️ 自动挂载

NetMounter 可以根据网络环境自动挂载共享：

1. 打开设置
2. 为服务器添加自动挂载规则
3. 选择目标网络（SSID 或有线连接）
4. 当连接到指定网络时自动挂载

## 🔒 安全

- 密码使用 macOS Keychain 安全存储
- 不会将敏感信息写入配置文件
- 本地运行，无网络追踪


## 🛠️ 开发

### 环境要求

- macOS 13.0+
- Xcode 15+ / Swift 5.9+
- Swift Package Manager

### 构建命令

```bash
# 运行调试版本
make run

# 构建发布版本
make build

# 打包为 .app
make package

# 清理构建产物
make clean
```

## 📄 许可证

MIT License - 详见 [LICENSE](LICENSE)

---

<p align="center">
  Made with ❤️ for macOS
</p>
