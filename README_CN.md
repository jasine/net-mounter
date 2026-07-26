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
- 🔌 **多协议支持** - SMB、AFP、NFS、WebDAV
- 📡 **网络发现** - 通过 Bonjour/mDNS 自动发现局域网服务器和共享
- 🤖 **自动挂载** - 根据网络环境自动挂载指定共享
- 🌐 **VPN 感知** - 自动检测 VPN 路由，连接 VPN 时自动挂载/断开时自动卸载
- 😴 **睡眠/唤醒重连** - 睡眠前优雅断开，唤醒后自动恢复所有挂载
- 🧟 **僵尸挂载自愈** - 自动检测并恢复无响应的挂载点
- 🔔 **系统通知** - 挂载成功、失败、恢复等事件实时推送通知
- 🔗 **链接分享** - 通过 `netmounter://` 链接一键分享服务器配置
- 📌 **固定文件夹** - 将常用子文件夹固定到服务器卡片，一键快速打开
- 📊 **动态状态图标** - 菜单栏图标实时反映挂载状态
- 🔐 **安全存储** - 密码安全存储在 macOS 钥匙串
- 🎨 **Liquid Glass UI** - 精美的毛玻璃界面设计
- 🚀 **开机自启** - 支持开机自动启动

## 🚀 快速开始

### 通过 Homebrew 安装

```bash
brew tap jasine/tap
brew install --cask netmounter
```

### 手动下载

从 [GitHub Releases](https://github.com/jasine/net-mounter/releases) 下载最新 DMG。

### 使用

1. 从 `/Applications` 启动 **NetMounter**
2. 点击菜单栏图标 📁
3. 点击 `+` 手动添加服务器，或点击 📡 自动发现局域网服务器
4. 输入连接信息并保存
5. 一键挂载！

## 🧭 配置指南

手动添加服务器（`+` 按钮）时，各字段填写说明：

| 字段 | 填写内容 | 示例 |
|------|----------|------|
| **名称** | 任意标签 | `家庭 NAS` |
| **协议** | 服务器使用的共享协议 | `SMB` |
| **主机名 / IP** | **仅填** IP 或主机名，不带 `smb://` 前缀，不带斜杠 | `192.168.1.50`、`nas.local`、`100.101.102.103`（Tailscale） |
| **共享路径** | SMB/AFP 只填共享**名称**；NFS 填完整导出路径 | SMB：`media` &nbsp;·&nbsp; NFS：`/volume1/media` |
| **用户名 / 密码** | 凭据（NFS 不需要） | `guest` |

提示：
- 对于 Windows 共享 `\\SERVER\media`，主机填 `SERVER`（或其 IP），共享路径填 `media`。
- **Tailscale**：主机名填该机器的 Tailscale IP（`100.x.x.x`）或 MagicDNS 名称，然后手动添加共享 —— 见下方发现说明。
- **NFS** 需要导出路径，并使用基于主机的访问控制，因此无需用户名/密码。

## 📡 网络发现

NetMounter 可以自动发现局域网内的网络服务器和共享：

1. 点击菜单栏弹窗中的 📡（天线）图标
2. NetMounter 通过 Bonjour/mDNS 扫描 SMB、AFP、NFS 服务器
3. 发现的 SMB/AFP 主机会自动探测是否也提供 NFS 服务（端口 2049）
4. 展开服务器可浏览其共享目录（SMB 通过 `smbutil`，NFS 通过 `showmount`）
5. 点击 `+` 将发现的共享添加到服务器列表

> **Bonjour 只能发现通过 mDNS 广播自身的主机** —— 主要是 NAS 设备和 Mac。
> 有两种常见情况不会出现在自动扫描中：
> - **Windows 共享** —— Windows 默认不通过 Bonjour 广播 SMB。
> - **Tailscale / VPN 主机** —— mDNS 是链路本地的，无法跨越 tailnet。
>
> **扫描子网**按钮：探测本地 `/24` 网段内每台主机的 SMB/AFP/NFS 端口，
> 可发现 Windows 共享等不广播的主机。Tailscale 主机位于路由式叠加网络
> （没有本地子网），请使用其 Tailscale IP 或 MagicDNS 名称**手动添加**（见配置指南）。

## 📋 支持的协议

| 协议 | 用途 | 挂载方式 |
|------|------|---------|
| **SMB** | Windows/NAS 文件共享 | NetFS（无需密码） |
| **AFP** | Apple 文件共享（旧版 Mac） | NetFS（无需密码） |
| **NFS** | Linux/Unix/NAS 文件共享 | 特权挂载（需管理员授权） |
| **WebDAV** | 网络存储（Nextcloud 等） | NetFS（无需密码） |

## ⚙️ 自动挂载

NetMounter 可以根据网络环境自动挂载共享：

1. 打开设置
2. 为服务器添加自动挂载规则
3. 选择目标网络（SSID 或有线连接）
4. 当连接到指定网络时自动挂载

## 🌐 VPN 感知

NetMounter 自动检测服务器是否通过 VPN 路由：

- 通过系统路由表判断服务器流量是否经过 VPN 接口（`utun`、`ipsec`、`ppp`）
- VPN 连接时自动挂载对应服务器（需开启自动挂载）
- VPN 断开时自动卸载通过 VPN 路由的服务器
- 无需手动配置，兼容任何 VPN 客户端

## 😴 睡眠/唤醒重连

再也不用担心睡眠后丢失网络挂载：

- 睡眠前：优雅断开所有网络挂载，防止产生僵尸卷
- 唤醒后：等待网络恢复后，自动重新连接所有挂载
- 网络恢复超时 30 秒，失败时发送通知提醒

## 🔗 链接分享

通过链接与团队共享服务器配置：

```
netmounter://add?host=192.168.1.100&proto=smb&share=shared&alias=NAS
```

- 点击服务器卡片上的链接图标即可复制分享链接
- 打开链接时会弹出确认对话框
- 自动检测重复配置
- 链接中不包含任何密码信息

## 🔒 安全

- 密码使用 macOS Keychain 安全存储
- 不会将敏感信息写入配置文件
- 本地运行，无网络追踪


## 🛠️ 开发

### 环境要求

- macOS 14.0+
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

# 创建 DMG 分发包
make dmg

# 清理构建产物
make clean
```

## 📄 许可证

MIT License - 详见 [LICENSE](LICENSE)

---

<p align="center">
  Made with ❤️ for macOS
</p>
