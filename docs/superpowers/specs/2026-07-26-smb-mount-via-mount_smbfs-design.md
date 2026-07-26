# SMB/AFP 改用 mount_smbfs 子进程 — 设计文档

日期：2026-07-26
分支：im-confused-about-the-setup

## 背景与根因

SMB 挂载在此环境永久卡死，用户看到 error 16（EBUSY）连锁。经最小复现程序 `/tmp/nettest`（独立调用 `NetFSMountURLSync`，脱离 app 全部逻辑）证实：

**`NetFSMountURLSync` 对该 SMB 共享永久挂起，不返回** —— 无论带不带 NoUI 选项、URL 带不带用户名、凭据是否传入。而系统命令 `mount_smbfs //jasine@192.168.1.2/media` 秒挂成功。

结论：根因是 `NetFSMountURLSync` 这个 API 在此环境不工作，不是 app 的调用参数。之前的三次修补（NoUI、去 URL user、超时）都是支线；其中超时保护有效，予以保留。

## 目标

SMB 挂载改用 `/sbin/mount_smbfs` 子进程执行，弃用 `NetFSMountURLSync`。像现有 NFS 挂载用 `/sbin/mount` 子进程一样。

## 非目标

- 不改 NFS 挂载路径（已用子进程，正常）。
- **AFP 暂不改**（用户决定：只用 SMB/NFS，AFP 用不到）。AFP 与 WebDAV 继续走 `NetFSMountURLSync`。若将来 AFP 也遇到同样的挂起，再单独处理。
- 不改发现流程的凭据输入（那是 Bug 2，单独设计）。
- 不引入系统钥匙串写入 / 特权 helper。

## 决策记录（用户拍板）

- **密码传递方式**：密码入 URL（`//user:password@host/share`）。用户在权衡后选择简单方案。
- **安全缓解（工程决定）**：密码与用户名**无条件做 percent-encoding**，兼容任意特殊字符（`@ : / # % 空格` 等），避免 URL 解析错误（这也是之前手动 `mount_smbfs` 码=1 的可能原因）。
- **已知残留风险（用户已接受）**：`mount_smbfs` 执行的瞬间，密码明文出现在进程命令行，同机其他用户 `ps` 可短暂窥见。单用户 Mac 场景可接受。设计中通过 `Process.arguments` 数组传参（不经 shell），把 URL 作为单个 argument，缩小暴露面到仅 `ps` 命令行，且不经过 shell 历史/日志。

## 方案

### 挂载执行（SMB 走子进程，AFP/WebDAV 保持 NetFS）

`mount(config:)` 分派：`.smb` → 新的 `mountSMB(config:completion:)`（子进程）；`.afp`/`.webdav` → 现有 `mountNetFS`（NetFSMountURLSync 保留）；`.nfs` → 现有 `mountNFS`。

`mountSMB` 用 `/sbin/mount_smbfs`。流程（复用现有 in-flight 锁 + 超时 + 校验）：
1. `config.isValidMountTarget` 校验（已有，拒绝空共享）。
2. `markInflight` 加锁；`wrappedCompletion` 释放锁（已有的一次性完成保护 + 超时保留）。
3. 挂载点 `/Volumes/<share末段>`。`mount_smbfs` 以普通用户权限自行创建挂载点（用户实测 `mount_smbfs //jasine@host/media /tmp/x` 普通权限成功），无需 root/osascript。
4. 构造认证 URL：`smb://<enc(user)>:<enc(password)>@<host>/<share>`，`enc()` 为 percent-encoding。无凭据时 `smb://<host>/<share>`。
5. `Process` 执行 `/sbin/mount_smbfs <authURL> <mountPoint>`（参数走 arguments 数组，不经 shell）。超时时 `process.terminate()` kill 子进程。
6. 读 stderr、`waitUntilExit`；exit 0 → 成功；非 0 → 解析 stderr 映射错误（认证失败 → authError，重试逻辑跳过）。

### percent-encoding 助手

在 `ServerConfig` 或 `MountingManager` 加一个纯函数 `smbCredentialEncoded(_:) -> String`，对 user/password 用 `CharacterSet` 白名单（`.alphanumerics` 加少量安全符号）做 `addingPercentEncoding`。纯函数，可单测。

### 超时与锁

复用已实现的 `netFSMountTimeout` 超时机制与一次性 `wrappedCompletion` 锁释放——子进程若卡住，超时同样释放锁。但 `mount_smbfs` 子进程可用 `Process` 直接 `terminate()`，比 NetFS 更可控：超时时 kill 子进程。

### 注入点（测试用）

将"执行挂载命令"抽象为可注入闭包（类似现有 `performNetFSMount`），使超时/锁/错误映射逻辑可单测，无需真实网络。

## 涉及改动

1. `MountingManager.swift`
   - `mount(config:)` 分派：`.smb` → 新的 `mountSMB`（子进程）；`.afp`/`.webdav` → 现有 `mountNetFS`（保留 NetFSMountURLSync）。
   - 新增 `mountSMB`：用 `/sbin/mount_smbfs`，认证 URL + Process 执行 + 超时 kill 子进程 + stderr 错误映射。
   - 移除临时诊断日志 `[diag]`。
   - 保留：超时、in-flight 锁、`isValidMountTarget` 校验、错误分类、AFP/WebDAV 的 NetFS 路径。
2. `ServerConfig.swift`（或 MountingManager）
   - 加 `smbCredentialEncoded` percent-encoding 助手。
   - 加构造 SMB 认证挂载 URL 的逻辑（不影响 `urlString` 显示 / `mountURLString`）。
3. 测试
   - percent-encoding 助手单测（含特殊字符）。
   - SMB 认证 URL 构造单测（有/无凭据、特殊字符密码）。
   - 超时释放锁（复用注入点，改成子进程执行注入）。

## 安全考量

- 密码 percent-encoded 后入 URL，URL 作为单个 `Process.arguments` 元素传递，不经 shell（无 shell 注入、无 shell 历史泄漏）。
- 残留：`ps` 命令行可见明文密码（用户已接受，单用户 Mac）。
- 挂载点限定 `/Volumes` 下，末段取自 share 名。

## 测试策略

- **单元**：percent-encoding（字母数字/特殊字符/空）、认证 URL 构造、超时释放锁、错误映射（认证失败 → 非重试）。
- **手动/真机**（需 NAS，代码无法自动化）：
  1. 配好凭据的 SMB 秒挂成功，出现在 /Volumes。
  2. 错密码 → 干净失败（认证错误），不卡死、不无限重试。
  3. 含特殊字符密码的服务器可挂。
  4. 断网/超时 → 超时释放锁，不永久占用。
