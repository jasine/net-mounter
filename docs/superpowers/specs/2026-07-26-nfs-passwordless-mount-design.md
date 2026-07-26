# NFS 免密自动挂载 — 设计文档

日期：2026-07-26
分支：im-confused-about-the-setup

## 背景与问题

每次打开 app 都会弹出 `osascript` 管理员密码框。根因：

- 只有 **NFS** 挂载需要 root。SMB/AFP/WebDAV 走 NetFS API，不需要密码。
- NFS 挂载执行 `mkdir -p /Volumes/xxx && /sbin/mount -t nfs ...`（`MountingManager.swift:268`），两步都需要 root，因此用 `osascript ... with administrator privileges` 弹框（`MountingManager.swift:272`）。
- 启动时 `AutoMountService` 会对配了自动挂载的 NFS 服务器执行挂载（首次 `silent=false` → 走带密码分支）。
- 睡眠/退出时挂载被卸载，所以每次启动都重新挂 → 每次都弹。

## 目标

保存**第一个 NFS 服务器**配置时，一次性安装一条 sudoers 免密规则（弹一次密码）。之后所有 NFS 挂载（自动或手动）都不再弹密码。

## 非目标

- 不提供"移除免密规则"的 UI 入口（用户确认不需要；如需撤销，手动删 `/etc/sudoers.d/` 文件）。
- 不改动 SMB/AFP/WebDAV 的挂载路径。
- 不使用 SMAppService 特权 helper / XPC（评估过，工程量过大，本次不做）。

## 方案（A1：root 拥有的 wrapper 脚本 + 收窄的 sudoers 规则）

### 为什么需要 wrapper 脚本

`/Volumes` 普通用户不可写，`mkdir` 也需要 root。若 sudoers 只给 `/sbin/mount_nfs` 免密，`mkdir` 仍会弹密码。因此安装一个 root 拥有的脚本，内部完成 `mkdir` + `mount_nfs`，sudoers 只对**这一个脚本**免密。脚本内校验参数，把可免密执行的操作限定为"在 `/Volumes` 下挂载 NFS"，比裸给通用 `/sbin/mount` 免密安全得多。

### 安装的文件

1. **wrapper 脚本**：`/Library/Application Support/NetMounter/nfs-mount.sh`
   - 属主 `root:wheel`，权限 `755`（仅 root 可写，防篡改 —— 这是 sudoers 免密安全性的前提）。
   - 内容（固定，不含用户可变数据）：
     ```sh
     #!/bin/sh
     # NetMounter NFS mount helper. Installed root-owned; invoked via passwordless sudo.
     set -e
     MOUNTPOINT="$1"
     SOURCE="$2"
     # 只允许挂载到 /Volumes 下，拒绝路径穿越
     case "$MOUNTPOINT" in
       /Volumes/*) ;;
       *) echo "refusing mountpoint outside /Volumes: $MOUNTPOINT" >&2; exit 1 ;;
     esac
     case "$MOUNTPOINT" in
       *..*) echo "refusing path traversal: $MOUNTPOINT" >&2; exit 1 ;;
     esac
     mkdir -p "$MOUNTPOINT"
     exec /sbin/mount_nfs -o resvport,noowners "$SOURCE" "$MOUNTPOINT"
     ```
2. **sudoers 片段**：`/etc/sudoers.d/netmounter`
   - 权限 `440`（sudoers 要求）。
   - 内容：
     ```
     ALL ALL=(root) NOPASSWD: /Library/Application\ Support/NetMounter/nfs-mount.sh
     ```
   - 注：路径含空格，sudoers 中用 `\` 转义空格。写入后用 `visudo -c -f` 校验语法，校验失败则回滚（删除片段），避免损坏 sudoers。

### 安装流程

一次性通过 `osascript ... with administrator privileges` 执行一段安装脚本（弹一次密码），该脚本：
1. `mkdir -p /Library/Application\ Support/NetMounter`
2. 写入 `nfs-mount.sh`，`chown root:wheel`，`chmod 755`
3. 写入 `/etc/sudoers.d/netmounter`，`chmod 440`
4. `visudo -cf /etc/sudoers.d/netmounter`（语法校验）；失败则 `rm` 掉该片段并以非 0 退出

安装脚本内容由 app 内硬编码常量生成，不拼接任何用户输入。

### 是否已安装的判断

`InstalledMarker`：检查 `/etc/sudoers.d/netmounter` 与 `/Library/Application Support/NetMounter/nfs-mount.sh` **同时存在**（`FileManager.fileExists`，无需 root 即可读到存在性）。两者都在才算已装；否则视为未装、需要安装。

### 挂载执行的改动

`mountNFS`（`MountingManager.swift:231`）：
- **已安装规则** → 执行 `sudo -n /Library/Application\ Support/NetMounter/nfs-mount.sh <mountPoint> <nfsSource>`，直接用 `Process` 跑 `/usr/bin/sudo`，`-n` 表示非交互（不弹密码）。参数通过 `Process.arguments` 数组传递，天然避免 shell 注入。
- **未安装规则** → 保持现有 `osascript ... with administrator privileges` 行为（向后兼容，未装也能用）。
- `silent=true` 分支（重试/健康检查）逻辑不变。

## 触发点与降级行为

### 触发（保存配置时）

在保存服务器配置的入口触发。`ServerDetailView.save()` → `appState.addServer` / `updateServer`。仅当：
- `config.serverProtocol == .nfs`，**且**
- 免密规则尚未安装（`InstalledMarker` 判断为未装）

时，调用安装流程（弹一次密码）。保存 SMB/AFP/WebDAV 不触发。

放置位置：在 `save()` 中、写入配置**之后**触发安装。安装是否成功不阻塞配置保存。

### 降级（用户取消授权）

若用户在授权框点取消：
- 不安装规则，**不阻止**配置保存（配置照常保存）。
- 后续 NFS 挂载因为 `InstalledMarker` 判定未装，自动退回老的 `osascript` 弹密码行为。
- 下次保存 NFS 配置时会再次尝试安装（因为仍判定未装）。即用户取消不是永久拒绝，只是这次不装。

## 涉及改动的文件

1. **新增** `NetMounter/Sources/NetMounter/Services/PrivilegedMountInstaller.swift`
   - `isInstalled: Bool`（检查两文件是否都存在）
   - `install(completion:)`（通过 osascript 执行安装脚本，弹一次密码；返回成功/取消/失败）
   - 硬编码的脚本常量（wrapper 脚本、sudoers 片段、安装脚本）
2. **修改** `MountingManager.swift`
   - `mountNFS`：根据 `PrivilegedMountInstaller.isInstalled` 选择 `sudo -n <脚本>` 或原 `osascript` 路径。
3. **修改** `ServerDetailView.swift`
   - `save()`：保存后，若为 NFS 且规则未装，触发 `PrivilegedMountInstaller.install`。

## 安全考量

- **脚本 root 拥有、非 root 不可写**：sudoers 免密的对象是固定脚本；用户无法改写脚本内容来提权。这是整个方案安全性的基石。
- **脚本内校验**：挂载点限定 `/Volumes/*`、拒绝 `..`，避免被诱导挂载到任意路径。
- **参数数组传递**：`sudo -n` 走 `Process.arguments`，不经 shell，无注入面。
- **sudoers 语法校验 + 回滚**：`visudo -cf` 校验失败即删除片段，不留下损坏的 sudoers。
- **残留风险（已接受）**：不提供卸载 UI，规则会长期存在。因规则被收窄到单个受控脚本，风险可接受。

## 测试策略

- **单元测试**：`PrivilegedMountInstaller.isInstalled` 的存在性判断逻辑（可注入路径）。脚本常量的转义正确性（sudoers 空格转义、路径校验分支）。
- **手动/集成验证**（需真实 NFS server，代码无法自动化）：
  1. 全新环境保存第一个 NFS 服务器 → 弹一次密码 → 文件被正确安装（属主/权限）。
  2. 之后挂载/重启 app 自动挂载 → 不再弹密码。
  3. 授权框点取消 → 配置仍保存，挂载退回老行为弹密码。
  4. `visudo -c` 通过，sudoers 未损坏。
